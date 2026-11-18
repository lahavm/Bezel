import AVFoundation
import Darwin
import Foundation

enum SessionError: LocalizedError {
    case socket(String)
    case disconnected
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .socket(let message): return "Socket error: \(message)"
        case .disconnected: return "Device disconnected."
        case .timeout: return "Timed out waiting for the device."
        case .server(let message): return message
        }
    }
}

/// One scrcpy session: pushes the server, opens a reverse tunnel,
/// and turns the video socket into CMSampleBuffers.
final class ScrcpySession: @unchecked Sendable {
    static let serverVersion = "5.0.1"
    static let remoteJar = "/data/local/tmp/bezel-server-\(serverVersion).jar"

    var onSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onSize: (@Sendable (Int, Int) -> Void)?
    var onEnd: (@Sendable (String?) -> Void)?

    private let adb: ADB
    private let device: Device
    private let scid = Int.random(in: 1...0x7FFF_FFFF)
    private var process: Process?
    private var listenFD: Int32 = -1
    private var connectionFD: Int32 = -1
    private let lock = NSLock()
    private var running = false

    init(device: Device, adb: ADB) {
        self.device = device
        self.adb = adb
    }

    private var jarURL: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("scrcpy-server.jar")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor")
            .appendingPathComponent("scrcpy-server-v\(Self.serverVersion)")
    }

    func start(settings: Settings) async throws {
        guard FileManager.default.fileExists(atPath: jarURL.path) else {
            throw SessionError.server("scrcpy-server.jar missing from the app bundle.")
        }

        try await adb.push(device.serial, local: jarURL, remote: Self.remoteJar)

        let listener = try makeListener()
        listenFD = listener.fd
        try await adb.reverse(
            device.serial,
            remote: "localabstract:scrcpy_\(scid)",
            localPort: listener.port
        )

        process = try adb.launchServer(
            device.serial,
            classpath: Self.remoteJar,
            arguments: serverArguments(settings: settings)
        )

        let fd = try await accept(listener.fd, timeout: 20)
        connectionFD = fd
        markRunning(true)

        // First four bytes on the video socket: codec id.
        let codec = try readExactly(fd, 4)
        guard let codecName = String(data: codec, encoding: .ascii), codecName.hasPrefix("h26") else {
            throw SessionError.server("Unsupported codec: \(String(decoding: codec, as: UTF8.self))")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop(fd)
        }
    }

    func stop() {
        markRunning(false)
        if connectionFD >= 0 {
            close(connectionFD)
            connectionFD = -1
        }
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        process?.terminate()
        process = nil
        let serial = device.serial
        let remote = "localabstract:scrcpy_\(scid)"
        Task { [adb] in
            await adb.removeReverse(serial, remote: remote)
            await adb.remove(serial, remote: Self.remoteJar)
        }
    }

    // MARK: - Server

    private func serverArguments(settings: Settings) -> [String] {
        var arguments = [
            Self.serverVersion,
            "scid=\(scid)",
            "log_level=error",
            "video=true",
            "audio=false",
            "control=false",
            "tunnel_forward=false",
            "send_device_meta=false",
            "cleanup=true",
            "max_fps=\(settings.fps)",
            "video_codec=\(settings.codec)"
        ]
        if settings.resolution != .native {
            arguments.append("max_size=\(settings.resolution.rawValue)")
        }
        if settings.source == .camera {
            arguments.append("video_source=camera")
            arguments.append("camera_facing=\(settings.cameraFacing)")
            arguments.append("camera_fps=\(settings.fps)")
        }
        return arguments
    }

    // MARK: - Stream

    private func readLoop(_ fd: Int32) {
        var format: CMVideoFormatDescription?

        while isRunning {
            guard let header = try? readExactly(fd, 12) else { break }
            let bytes = [UInt8](header)

            if bytes[0] & 0x80 != 0 {
                let width = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
                let height = Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
                onSize?(width, height)
                continue
            }

            var field: UInt64 = 0
            for index in 0..<8 { field = (field << 8) | UInt64(bytes[index]) }
            let isConfig = field & 0x4000_0000_0000_0000 != 0
            let pts = Int64(field & 0x1FFF_FFFF_FFFF_FFFF)
            let size = Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
            guard size > 0, size < 32 * 1024 * 1024 else { break }
            guard let payload = try? readExactly(fd, size) else { break }

            if isConfig {
                format = H264Frames.formatDescription(fromConfig: payload)
            } else if let format,
                      let avcc = H264Frames.avcc(from: payload),
                      let sample = H264Frames.sampleBuffer(avcc: avcc, format: format, ptsMicros: pts) {
                onSample?(sample)
            }
        }

        let wasRunning = isRunning
        markRunning(false)
        if wasRunning { onEnd?("Stream ended.") }
    }

    private func isRunningValue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private var isRunning: Bool { isRunningValue() }

    private func markRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }

    // MARK: - Sockets

    private func makeListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SessionError.socket("socket() failed") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SessionError.socket("bind() failed: \(errno)")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw SessionError.socket("listen() failed: \(errno)")
        }

        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw SessionError.socket("getsockname() failed: \(errno)")
        }
        return (fd, UInt16(bigEndian: result.sin_port))
    }

    private func accept(_ fd: Int32, timeout: Int) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(timeout * 1000))
                guard ready > 0 else {
                    continuation.resume(throwing: SessionError.timeout)
                    return
                }
                let connection = Darwin.accept(fd, nil, nil)
                if connection >= 0 {
                    continuation.resume(returning: connection)
                } else {
                    continuation.resume(throwing: SessionError.socket("accept() failed: \(errno)"))
                }
            }
        }
    }

    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw SessionError.disconnected }
            while offset < count {
                let readCount = read(fd, base + offset, count - offset)
                if readCount <= 0 { throw SessionError.disconnected }
                offset += readCount
            }
        }
        return data
    }
}

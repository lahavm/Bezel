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
    var onAudioConfig: (@Sendable (Data) -> Void)?
    var onAudioFrame: (@Sendable (Data, Int64) -> Void)?
    var onEnd: (@Sendable (String?) -> Void)?

    private let adb: ADB
    private let device: Device
    private let scid = Int.random(in: 1...0x7FFF_FFFF)
    private var scidHex: String { String(format: "%08x", scid) }
    private var process: Process?
    private var listenFD: Int32 = -1
    private var connectionFD: Int32 = -1
    private var audioFD: Int32 = -1
    private(set) var audioConfig: Data?
    private let lock = NSLock()
    private var running = false

    init(device: Device, adb: ADB) {
        self.device = device
        self.adb = adb
    }

    var deviceSerial: String { device.serial }
    var reverseTarget: String { "localabstract:\(socketName)" }

    private var socketName: String {
        "scrcpy_\(scidHex)"
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

        Log.write("session: push \(jarURL.lastPathComponent) to \(Self.remoteJar)")
        try await adb.push(device.serial, local: jarURL, remote: Self.remoteJar)

        let listener = try makeListener()
        Log.write("session: listening on 127.0.0.1:\(listener.port) scid=\(scid) socket=\(socketName)")
        listenFD = listener.fd
        try await adb.reverse(
            device.serial,
            remote: "localabstract:\(socketName)",
            localPort: listener.port
        )
        Log.write("session: reverse tunnel ready")

        process = try adb.launchServer(
            device.serial,
            classpath: Self.remoteJar,
            arguments: serverArguments(settings: settings)
        )

        Log.write("session: server started, waiting for connection")
        let fd = try await accept(listener.fd, timeout: 20)
        connectionFD = fd
        markRunning(true)
        Log.write("session: connected")

        // First four bytes on the video socket: codec id.
        let codec = try readExactly(fd, 4)
        guard let codecName = String(data: codec, encoding: .ascii), codecName.hasPrefix("h26") else {
            throw SessionError.server("Unsupported codec: \(String(decoding: codec, as: UTF8.self))")
        }
        Log.write("session: codec \(codecName)")

        if settings.audio != .none {
            startAudio(listener.fd)
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
        if audioFD >= 0 {
            close(audioFD)
            audioFD = -1
        }
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        process?.terminate()
        process = nil
        let serial = device.serial
        let remote = "localabstract:\(socketName)"
        Task { [adb] in
            await adb.removeReverse(serial, remote: remote)
            await adb.remove(serial, remote: Self.remoteJar)
        }
    }

    // MARK: - Server

    private func serverArguments(settings: Settings) -> [String] {
        var arguments = [
            Self.serverVersion,
            "scid=\(scidHex)",
            "log_level=error",
            "video=true",
            "audio=\(settings.audio != .none)",
            "control=false",
            "tunnel_forward=false",
            "send_device_meta=false",
            "cleanup=true",
            "video_codec=\(settings.codec)",
            // A keyframe every second keeps screenshots exact and recordings seekable.
            "video_codec_options=i-frame-interval=1"
        ]
        if settings.fps > 0 {
            arguments.append("max_fps=\(settings.fps)")
        }
        if settings.audio != .none {
            arguments.append("audio_codec=aac")
            arguments.append("audio_source=\(settings.audio == .microphone ? "mic" : "output")")
        }
        if settings.resolution != .native {
            arguments.append("max_size=\(settings.resolution.rawValue)")
        }
        if settings.source == .camera {
            arguments.append("video_source=camera")
            if let cameraId = settings.cameraId {
                arguments.append("camera_id=\(cameraId)")
            } else {
                arguments.append("camera_facing=\(settings.cameraFacing)")
            }
            if settings.fps > 0 {
                arguments.append("camera_fps=\(settings.fps)")
            }
            switch settings.resolution {
            case .uhd: arguments.append("camera_size=3840x2160")
            case .qhd: arguments.append("camera_size=2560x1440")
            case .fhd: arguments.append("camera_size=1920x1080")
            case .hd: arguments.append("camera_size=1280x720")
            case .native: break
            }
        }
        return arguments
    }

    private func startAudio(_ listener: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fd = try self.acceptSync(listener, timeout: 10)
                self.audioFD = fd
                let codec = try self.readExactly(fd, 4)
                let name = String(decoding: codec, as: UTF8.self)
                guard name.hasSuffix("aac") else {
                    Log.write("audio: device disabled the stream (\(name.debugDescription))")
                    close(fd)
                    return
                }
                Log.write("audio: codec \(name)")
                self.readAudioLoop(fd)
            } catch {
                Log.write("audio: \(error.localizedDescription)")
            }
        }
    }

    private func readAudioLoop(_ fd: Int32) {
        var format: CMAudioFormatDescription?
        var frames = 0

        while isRunning {
            guard let header = try? readExactly(fd, 12) else { break }
            let bytes = [UInt8](header)
            var field: UInt64 = 0
            for index in 0..<8 { field = (field << 8) | UInt64(bytes[index]) }
            let isConfig = field & 0x4000_0000_0000_0000 != 0
            let pts = Int64(field & 0x1FFF_FFFF_FFFF_FFFF)
            let size = Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
            guard size > 0, size < 1024 * 1024 else { break }
            guard let payload = try? readExactly(fd, size) else { break }

            if isConfig {
                Log.write("audio: config \(payload.count) bytes \(payload.map { String(format: "%02x", $0) }.joined())")
                format = AudioFrames.formatDescription(asc: payload)
                if format != nil {
                    self.audioConfig = payload
                    onAudioConfig?(payload)
                }
            } else if let format,
                      let sample = AudioFrames.sampleBuffer(frame: payload, format: format, ptsMicros: pts) {
                frames += 1
                if frames == 1 || frames % 200 == 0 {
                    Log.write("audio: frames=\(frames) pts=\(pts)")
                }
                onAudioFrame?(payload, pts)
                _ = sample
            }
        }
        Log.write("audio: loop ended after \(frames) frames")
    }

    // MARK: - Stream

    private func readLoop(_ fd: Int32) {
        var format: CMVideoFormatDescription?
        var samples = 0

        while isRunning {
            guard let header = try? readExactly(fd, 12) else { break }
            let bytes = [UInt8](header)

            if bytes[0] & 0x80 != 0 {
                let width = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
                let height = Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
                Log.write("session: video size \(width)x\(height)")
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
                Log.write("session: config packet \(payload.count) bytes, format=\(format != nil)")
            } else if let format,
                      let avcc = H264Frames.avcc(from: payload),
                      let sample = H264Frames.sampleBuffer(avcc: avcc, format: format, ptsMicros: pts) {
                samples += 1
                if samples == 1 || samples % 120 == 0 {
                    Log.write("session: samples=\(samples) pts=\(pts)")
                }
                onSample?(sample)
            }
        }

        let wasRunning = isRunning
        markRunning(false)
        Log.write("session: read loop ended after \(samples) samples")
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
        guard listen(fd, 2) == 0 else {
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

    private func acceptSync(_ fd: Int32, timeout: Int) throws -> Int32 {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(timeout * 1000))
        guard ready > 0 else { throw SessionError.timeout }
        let connection = Darwin.accept(fd, nil, nil)
        guard connection >= 0 else { throw SessionError.socket("accept() failed: \(errno)") }
        return connection
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

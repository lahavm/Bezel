import Foundation

struct Device: Identifiable, Hashable, Sendable {
    let serial: String
    let model: String
    let android: String
    let sdk: Int
    let state: String

    var id: String { serial }
    var displayName: String { model.isEmpty ? serial : model }
    var isReady: Bool { state == "device" }
}

struct CameraInfo: Identifiable, Hashable, Sendable {
    let id: Int
    let facing: String
    let size: String
    let fps: String

    var label: String {
        let side = facing.prefix(1).uppercased() + facing.dropFirst()
        return "\(side) · \(size)"
    }
}

enum ADBError: LocalizedError {
    case toolNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound: return "Bundled adb not found."
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "adb failed." : trimmed
        }
    }
}

/// Thin wrapper around the bundled adb binary.
/// Uses a private key store and server port so it never touches the user's ~/.android.
final class ADB: @unchecked Sendable {
    let adbURL: URL
    /// Whether this run of the app spawned the adb daemon. Only then is it
    /// ours to stop on quit.
    private(set) var startedServer = false

    private let userHome: URL

    init() {
        adbURL = ADB.locateTool("adb", subdirectory: "platform-tools")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bezel", isDirectory: true)
        userHome = support.appendingPathComponent("android", isDirectory: true)
        try? FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
    }

    /// App bundle first, then the repository Vendor folder for `swift run`.
    private static func locateTool(_ name: String, subdirectory: String?) -> URL {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
            if let subdirectory {
                candidates.append(resources.appendingPathComponent(subdirectory).appendingPathComponent(name))
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let subdirectory {
            candidates.append(cwd.appendingPathComponent("Vendor").appendingPathComponent(subdirectory).appendingPathComponent(name))
        }
        candidates.append(cwd.appendingPathComponent("Vendor").appendingPathComponent(name))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return URL(fileURLWithPath: "/usr/bin/false")
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Used only if this client has to start a daemon. An already running
        // server keeps its own keys, so an authorized device stays authorized.
        env["ANDROID_USER_HOME"] = userHome.path
        return env
    }

    private func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = adbURL
        process.arguments = arguments
        process.environment = environment()
        return process
    }

    func run(_ arguments: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: adbURL.path) else {
            throw ADBError.toolNotFound
        }
        let process = process(arguments)
        process.standardInput = FileHandle.nullDevice

        // Redirect to a temp file instead of a pipe: an adb daemon forked by a
        // client inherits the descriptor, which keeps a pipe open forever.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bezel-adb-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw ADBError.failed("Could not create a temporary output file.")
        }
        process.standardOutput = handle
        process.standardError = handle
        defer { try? FileManager.default.removeItem(at: outputURL) }

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                try? handle.close()
                continuation.resume(throwing: ADBError.failed(error.localizedDescription))
                return
            }
            process.terminationHandler = { finished in
                try? handle.close()
                let data = (try? Data(contentsOf: outputURL)) ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: ADBError.failed(text))
                }
            }
        }
    }

    /// True when a daemon owned by anything else (Android Studio, Homebrew)
    /// already answers on the default adb port.
    private func serverIsRunning() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(5037).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func startServer() async throws {
        guard FileManager.default.isExecutableFile(atPath: adbURL.path) else {
            throw ADBError.toolNotFound
        }
        if serverIsRunning() {
            return
        }
        let process = process(["start-server"])
        // The daemon inherits the pipe, so a captured stdout would never close.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    self.startedServer = true
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ADBError.failed("adb start-server failed"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ADBError.failed(error.localizedDescription))
            }
        }
    }

    func devices() async throws -> [Device] {
        try await startServer()
        let output = try await run(["devices", "-l"])
        var devices: [Device] = []
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2 else { continue }
            let serial = String(columns[0])
            let state = String(columns[1])
            guard state == "device" || state == "unauthorized" || state == "offline" else { continue }
            var model = ""
            for column in columns where column.hasPrefix("model:") {
                model = column.replacingOccurrences(of: "model:", with: "").replacingOccurrences(of: "_", with: " ")
            }
            var android = ""
            var sdk = 0
            if state == "device" {
                android = (try? await shell(serial, ["getprop", "ro.build.version.release"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                sdk = Int((try? await shell(serial, ["getprop", "ro.build.version.sdk"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                if model.isEmpty {
                    model = (try? await shell(serial, ["getprop", "ro.product.model"]))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            }
            devices.append(Device(serial: serial, model: model, android: android, sdk: sdk, state: state))
        }
        return devices
    }

    func shell(_ serial: String, _ arguments: [String]) async throws -> String {
        try await run(["-s", serial, "shell"] + arguments)
    }

    func shellCommand(_ serial: String, _ command: String) async throws -> String {
        try await run(["-s", serial, "shell", command])
    }

    func push(_ serial: String, local: URL, remote: String) async throws {
        _ = try await run(["-s", serial, "push", local.path, remote])
    }

    /// Synchronous variant for app termination, where async work would be cut off.
    @discardableResult
    func runSync(_ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: adbURL.path) else { return false }
        let process = process(arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func cleanupSync(serial: String, remoteJar: String, reverse: String) {
        runSync(["-s", serial, "shell", "rm", "-f", remoteJar])
        runSync(["-s", serial, "reverse", "--remove", reverse])
    }

    func remove(_ serial: String, remote: String) async {
        _ = try? await run(["-s", serial, "shell", "rm", "-f", remote])
    }

    func reverse(_ serial: String, remote: String, localPort: UInt16) async throws {
        _ = try await run(["-s", serial, "reverse", remote, "tcp:\(localPort)"])
    }

    func removeReverse(_ serial: String, remote: String) async {
        _ = try? await run(["-s", serial, "reverse", "--remove", remote])
    }

    /// Asks the device which cameras it exposes and what they support.
    func cameras(_ serial: String, jar: URL, version: String) async -> [CameraInfo] {
        let remote = "/data/local/tmp/bezel-camera-probe.jar"
        do {
            try await push(serial, local: jar, remote: remote)
            let command = "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server "
                + "\(version) list_cameras=true log_level=info audio=false video=false control=false"
            let output = try await shellCommand(serial, command)
            await remove(serial, remote: remote)
            return parseCameras(output)
        } catch {
            Log.write("cameras: probe failed \(error.localizedDescription)")
            return []
        }
    }

    private func parseCameras(_ output: String) -> [CameraInfo] {
        var cameras: [CameraInfo] = []
        for line in output.split(separator: "\n") where line.contains("--camera-id=") {
            guard let idRange = line.range(of: "--camera-id=") else { continue }
            let rest = line[idRange.upperBound...]
            let parts = rest.split(separator: "(", maxSplits: 1)
            guard parts.count == 2, let id = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let fields = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { continue }
            let fps = fields[2]
                .replacingOccurrences(of: "fps={", with: "")
                .replacingOccurrences(of: "}", with: "")
                .replacingOccurrences(of: " ", with: "")
            let size = fields[1].replacingOccurrences(of: " ", with: "")
            cameras.append(CameraInfo(id: id, facing: fields[0], size: size, fps: fps))
        }
        return cameras
    }

    func launchServer(_ serial: String, classpath: String, arguments: [String]) throws -> Process {
        let command = "CLASSPATH=\(classpath) app_process / com.genymobile.scrcpy.Server " + arguments.joined(separator: " ")
        let process = process(["-s", serial, "shell", command])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                Log.write("server: \(line)")
            }
        }
        try process.run()
        return process
    }
}

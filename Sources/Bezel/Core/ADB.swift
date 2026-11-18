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
    static let serverPort = 5038

    let adbURL: URL
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
        env["ANDROID_USER_HOME"] = userHome.path
        env["ANDROID_ADB_SERVER_PORT"] = String(Self.serverPort)
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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ADBError.failed(error.localizedDescription))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: ADBError.failed(text))
                }
            }
        }
    }

    func startServer() async throws {
        _ = try? await run(["start-server"])
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

    func remove(_ serial: String, remote: String) async {
        _ = try? await run(["-s", serial, "shell", "rm", "-f", remote])
    }

    func reverse(_ serial: String, remote: String, localPort: UInt16) async throws {
        _ = try await run(["-s", serial, "reverse", remote, "tcp:\(localPort)"])
    }

    func removeReverse(_ serial: String, remote: String) async {
        _ = try? await run(["-s", serial, "reverse", "--remove", remote])
    }

    func launchServer(_ serial: String, classpath: String, arguments: [String]) throws -> Process {
        let command = "CLASSPATH=\(classpath) app_process / com.genymobile.scrcpy.Server " + arguments.joined(separator: " ")
        let process = process(["-s", serial, "shell", command])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }
}

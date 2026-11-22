import Foundation

/// The Android side of the file browser. Everything goes through the bundled
/// adb binary; nothing is installed on the phone.
final class ADBBackend: FileBackend, @unchecked Sendable {
    let id: String
    let name: String
    let serial: String
    let root: String
    let defaultPath: String
    let isRemote = true

    private let adb: ADB

    init(adb: ADB, serial: String, name: String, root: String = "/sdcard") {
        self.adb = adb
        self.serial = serial
        self.name = name
        self.root = root
        self.id = "\(serial):\(root)"
        self.defaultPath = root
    }

    // MARK: - Shell helpers

    private func shell(_ command: String) async throws -> String {
        let result = try await adb.captured(["-s", serial, "shell", command])
        guard result.status == 0 else {
            let text = result.stderr.isEmpty
                ? String(decoding: result.stdout, as: UTF8.self)
                : result.stderr
            throw FileError.fromADB(text)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func quietShell(_ command: String) async -> String {
        let result = try? await adb.captured(["-s", serial, "shell", command])
        return String(decoding: result?.stdout ?? Data(), as: UTF8.self)
    }

    /// Toybox `stat` fields: size, mtime, raw mode, permissions, name.
    private static let statFormat = "%s|%Y|%f|%A|%n"

    static func parseStat(_ text: String, backendID: String, base: String) -> [FileItem] {
        var items: [FileItem] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5,
                  let size = Int64(fields[0].trimmingCharacters(in: .whitespaces)),
                  let mtime = TimeInterval(fields[1].trimmingCharacters(in: .whitespaces)),
                  let mode = UInt32(fields[2].trimmingCharacters(in: .whitespaces), radix: 16)
            else { continue }

            var name = fields[4]
            if name.hasPrefix("./") { name.removeFirst(2) }
            // A literal glob from an empty directory is not a file.
            guard !name.contains("*"), !name.isEmpty else { continue }

            let typeMask = mode & 0xF000
            let isDirectory = typeMask == 0x4000
            let permissions = fields[3].trimmingCharacters(in: .whitespaces)
            let isSymlink = typeMask == 0xA000 || permissions.hasPrefix("l")

            items.append(FileItem(
                backendID: backendID,
                path: FilePath.join(base, name),
                name: name,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: isDirectory ? 0 : size,
                modified: Date(timeIntervalSince1970: mtime),
                permissions: permissions
            ))
        }
        return items
    }

    // MARK: - Browsing

    func list(_ path: String) async throws -> [FileItem] {
        let command = "cd \(shellQuote(path)) 2>/dev/null && "
            + "stat -c '\(Self.statFormat)' ./* ./.[!.]* 2>/dev/null"
        let text = await quietShell(command)
        return Self.parseStat(text, backendID: id, base: path)
    }

    func info(_ path: String) async throws -> FileItem {
        guard let parent = FilePath.parent(path) else {
            throw FileError.missing(path)
        }
        let command = "cd \(shellQuote(parent)) && "
            + "stat -c '\(Self.statFormat)' ./\(shellQuote(FilePath.name(path)))"
        let text = try await shell(command)
        guard let item = Self.parseStat(text, backendID: id, base: parent).first else {
            throw FileError.missing(path)
        }
        return item
    }

    func exists(_ path: String) async throws -> Bool {
        let text = try await shell("[ -e \(shellQuote(path)) ] && echo yes || echo no")
        return text.contains("yes")
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await shell("mkdir -p \(shellQuote(path))")
    }

    func move(_ path: String, to newPath: String) async throws {
        if let parent = FilePath.parent(newPath) {
            _ = try? await shell("mkdir -p \(shellQuote(parent))")
        }
        _ = try await shell("mv -f \(shellQuote(path)) \(shellQuote(newPath))")
    }

    func copy(_ path: String, to newPath: String) async throws {
        if let parent = FilePath.parent(newPath) {
            _ = try? await shell("mkdir -p \(shellQuote(parent))")
        }
        let from = shellQuote(path)
        let to = shellQuote(newPath)
        let result = try await adb.captured(["-s", serial, "shell", "cp -a \(from) \(to) || cp -R \(from) \(to)"])
        if result.status != 0 {
            throw FileError.fromADB(result.stderr.isEmpty ? String(decoding: result.stdout, as: UTF8.self) : result.stderr)
        }
    }

    func delete(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let quoted = paths.map(shellQuote).joined(separator: " ")
        _ = try await shell("rm -rf \(quoted)")
    }

    func search(_ query: String, in path: String, deep: Bool) async throws -> [FileItem] {
        guard !query.isEmpty else { return [] }
        let pattern = shellQuote("*" + query + "*")
        let depth = deep ? 7 : 1
        let command = "find \(shellQuote(path)) -maxdepth \(depth) -iname \(pattern) -print 2>/dev/null | head -300"
        let text = try await shell(command)
        let paths = text.split(separator: "\n").prefix(200).map(String.init)
        var results: [FileItem] = []
        for found in paths {
            try Task.checkCancellation()
            if let item = try? await info(found) {
                results.append(item)
            }
        }
        return results
    }

    func read(_ path: String, maxBytes: Int) async throws -> Data {
        let result = try await adb.captured([
            "-s", serial, "exec-out", "head -c \(maxBytes) \(shellQuote(path))"
        ])
        guard result.status == 0 else { throw FileError.fromADB(result.stderr) }
        return result.stdout
    }

    func freeSpace(at path: String) -> (free: Int64, total: Int64)? {
        nil // Filled in by FilesCoordinator on the main actor via `capacity()`.
    }

    func capacity(at path: String) async -> (free: Int64, total: Int64)? {
        let text = await quietShell("df -k \(shellQuote(path)) 2>/dev/null")
        let lines = text.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4,
              let available = Int64(fields[3]),
              let used = Int64(fields[2])
        else { return nil }
        return (available * 1024, (available + used) * 1024)
    }

    func measure(_ path: String) async throws -> (bytes: Int64, files: Int) {
        let item = try await info(path)
        if !item.isDirectory { return (item.size, 1) }
        var bytes: Int64 = 0
        var files = 0
        try await measureDirectory(path, into: &bytes, files: &files)
        return (bytes, files)
    }

    private func measureDirectory(_ path: String, into bytes: inout Int64, files: inout Int) async throws {
        for item in try await list(path) {
            try Task.checkCancellation()
            if item.isDirectory {
                try await measureDirectory(item.path, into: &bytes, files: &files)
            } else {
                bytes += item.size
                files += 1
            }
        }
    }

    // MARK: - Streaming transfer

    func download(_ path: String, to url: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let child = adb.stream([
            "-s", serial, "exec-out", "cat \(shellQuote(path))"
        ])
        do {
            try child.start()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }

            var written: Int64 = 0
            var reported: Int64 = 0
            for try await chunk in child.output() {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                if written - reported >= 1_048_576 {
                    onBytes(written - reported)
                    reported = written
                }
            }
            if written > reported { onBytes(written - reported) }
            let result = await child.wait()
            guard result.status == 0 else { throw FileError.fromADB(result.stderr) }
        } catch {
            child.terminate()
            if error is CancellationError { throw FileError.cancelled }
            throw error
        }
    }

    func upload(_ url: URL, to path: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        if let parent = FilePath.parent(path) {
            _ = try? await shell("mkdir -p \(shellQuote(parent))")
        }
        let temporary = "\(path).bezelpart-\(UUID().uuidString)"
        let child = adb.stream([
            "-s", serial, "exec-in", "cat > \(shellQuote(temporary))"
        ])
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try child.start()

            var reported: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                try child.write(chunk)
                reported += Int64(chunk.count)
                if reported >= 1_048_576 {
                    onBytes(reported)
                    reported = 0
                }
            }
            if reported > 0 { onBytes(reported) }
            child.closeInput()
            let result = await child.wait()
            guard result.status == 0 else { throw FileError.fromADB(result.stderr) }
            _ = try await shell("mv -f \(shellQuote(temporary)) \(shellQuote(path))")
        } catch {
            child.terminate()
            _ = try? await shell("rm -f \(shellQuote(temporary))")
            if error is CancellationError { throw FileError.cancelled }
            throw error
        }
    }
}

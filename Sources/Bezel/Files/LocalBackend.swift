import Foundation

/// The Mac side of the file browser.
final class LocalBackend: FileBackend, @unchecked Sendable {
    let id = "local"
    let name = "This Mac"
    let defaultPath: String
    let isRemote = false

    private let manager = FileManager.default

    init() {
        defaultPath = NSHomeDirectory()
    }

    private func fileItem(at path: String) throws -> FileItem {
        let attributes = try manager.attributesOfItem(atPath: path)
        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let isSymlink = fileType == .typeSymbolicLink
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        return FileItem(
            backendID: id,
            path: path,
            name: FilePath.name(path),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: isDirectory ? 0 : size,
            modified: (attributes[.modificationDate] as? Date) ?? Date.distantPast,
            permissions: Self.permissionString(mode, isDirectory: isDirectory)
        )
    }

    static func permissionString(_ mode: UInt16, isDirectory: Bool) -> String {
        var result = isDirectory ? "d" : "-"
        for shift in [UInt16(6), 3, 0] {
            let bits = (mode >> shift) & 7
            result += (bits & 4 != 0 ? "r" : "-")
            result += (bits & 2 != 0 ? "w" : "-")
            result += (bits & 1 != 0 ? "x" : "-")
        }
        return result
    }

    func list(_ path: String) async throws -> [FileItem] {
        let names = try manager.contentsOfDirectory(atPath: path)
        var items: [FileItem] = []
        for name in names {
            let full = FilePath.join(path, name)
            if let item = try? fileItem(at: full) {
                items.append(item)
            }
        }
        return items.naturalSorted()
    }

    func info(_ path: String) async throws -> FileItem {
        try fileItem(at: path)
    }

    func exists(_ path: String) async throws -> Bool {
        manager.fileExists(atPath: path)
    }

    func makeDirectory(_ path: String) async throws {
        try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func move(_ path: String, to newPath: String) async throws {
        try manager.moveItem(atPath: path, toPath: newPath)
    }

    func copy(_ path: String, to newPath: String) async throws {
        try manager.copyItem(atPath: path, toPath: newPath)
    }

    func delete(_ paths: [String]) async throws {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                try manager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try manager.removeItem(at: url)
            }
        }
    }

    func search(_ query: String, in path: String, deep: Bool) async throws -> [FileItem] {
        guard !query.isEmpty else { return [] }
        var results: [FileItem] = []

        func matches(_ name: String) -> Bool {
            name.localizedCaseInsensitiveContains(query)
        }

        if !deep {
            for name in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where matches(name) {
                if let found = try? fileItem(at: FilePath.join(path, name)) {
                    results.append(found)
                }
            }
        } else {
            let subpaths = (try? manager.subpathsOfDirectory(atPath: path)) ?? []
            for relative in subpaths {
                if Task.isCancelled { break }
                if !matches(FilePath.name(relative)) { continue }
                if let found = try? fileItem(at: FilePath.join(path, relative)) {
                    results.append(found)
                }
                if results.count >= 300 { break }
            }
        }
        return results.naturalSorted()
    }

    func read(_ path: String, maxBytes: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    func download(_ path: String, to url: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        try copyFile(URL(fileURLWithPath: path), to: url, onBytes: onBytes)
    }

    func upload(_ url: URL, to path: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        try copyFile(url, to: URL(fileURLWithPath: path), onBytes: onBytes)
    }

    private func copyFile(_ from: URL, to: URL, onBytes: @escaping @Sendable (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: to)
        FileManager.default.createFile(atPath: to.path, contents: nil)
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        while true {
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            onBytes(Int64(chunk.count))
        }
    }

    func freeSpace(at path: String) -> (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ])
        let free = values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        return (free, total)
    }

    func measure(_ path: String) async throws -> (bytes: Int64, files: Int) {
        let item = try fileItem(at: path)
        if !item.isDirectory { return (item.size, 1) }
        var bytes: Int64 = 0
        var files = 0
        let subpaths = (try? manager.subpathsOfDirectory(atPath: path)) ?? []
        for relative in subpaths {
            if Task.isCancelled { break }
            let full = FilePath.join(path, relative)
            guard let child = try? fileItem(at: full), !child.isDirectory else { continue }
            bytes += child.size
            files += 1
        }
        return (bytes, files)
    }
}

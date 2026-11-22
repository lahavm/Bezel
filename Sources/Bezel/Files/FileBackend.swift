import Foundation

enum FileError: LocalizedError, Sendable {
    case missing(String)
    case notADirectory(String)
    case permissionDenied(String)
    case deviceOffline(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let path): return "“\(path)” no longer exists."
        case .notADirectory(let path): return "“\(path)” is not a folder."
        case .permissionDenied(let path): return "You can’t access “\(path)”."
        case .deviceOffline(let name): return "\(name) is no longer connected."
        case .cancelled: return "The transfer was cancelled."
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The operation failed." : trimmed
        }
    }

    /// A friendlier message for adb's common failures.
    static func fromADB(_ output: String) -> FileError {
        let lower = output.lowercased()
        if lower.contains("permission denied") { return .permissionDenied(output) }
        if lower.contains("no such file") { return .missing(output) }
        if lower.contains("not a directory") { return .notADirectory(output) }
        if lower.contains("device offline") || lower.contains("device not found") {
            return .deviceOffline("The device")
        }
        return .failed(output)
    }
}

enum ConflictChoice: Sendable {
    case replace
    case keepBoth
    case skip
}

struct FileConflict: Sendable {
    let name: String
    let existingSize: Int64
    let newSize: Int64
    let isDirectory: Bool
}

/// A source of files. Both the Mac and each Android device implement this,
/// so the browser and the transfer queue speak one language.
protocol FileBackend: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }
    /// Absolute path shown when the backend is first opened.
    var defaultPath: String { get }
    var isRemote: Bool { get }

    func list(_ path: String) async throws -> [FileItem]
    func info(_ path: String) async throws -> FileItem
    func exists(_ path: String) async throws -> Bool
    func makeDirectory(_ path: String) async throws
    func move(_ path: String, to newPath: String) async throws
    func copy(_ path: String, to newPath: String) async throws
    func delete(_ paths: [String]) async throws
    func search(_ query: String, in path: String, deep: Bool) async throws -> [FileItem]
    func read(_ path: String, maxBytes: Int) async throws -> Data

    /// Copies one file. Folders are walked by `TransferCenter`.
    func download(_ path: String, to url: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws
    func upload(_ url: URL, to path: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws

    func freeSpace(at path: String) -> (free: Int64, total: Int64)?

    /// Total bytes and file count below a path, for honest progress bars.
    func measure(_ path: String) async throws -> (bytes: Int64, files: Int)
}

/// Shell-quote a single argument defensively. Android's toybox utilities are
/// invoked through adb's remote shell, so paths with spaces and quotes must
/// survive one more round of parsing.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum FilePath {
    static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(_ path: String) -> String? {
        let trimmed = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        guard trimmed != "/" else { return nil }
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    static func components(_ path: String, root: String) -> [String] {
        guard path.hasPrefix(root) else {
            return path.split(separator: "/").map(String.init)
        }
        let rest = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rest.isEmpty ? [] : rest.split(separator: "/").map(String.init)
    }

    /// "Report 2.pdf" when "Report.pdf" already exists, matching Finder.
    static func conflictName(for name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
    }
}

/// One in-flight or finished copy. The UI reads these; the transfer center
/// mutates them on the main actor.
struct TransferJob: Identifiable, Sendable {
    enum State: String, Sendable {
        case waiting
        case preparing
        case running
        case finished
        case skipped
        case failed
        case cancelled

        var isActive: Bool {
            self == .waiting || self == .preparing || self == .running
        }
    }

    let id = UUID()
    let source: FileItem
    let sourceBackend: any FileBackend
    let destinationBackend: any FileBackend
    let destinationDirectory: String
    var destinationName: String
    var state: State = .waiting
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var speed: Double = 0
    var started = Date()
    var finished: Date?
    var message: String?
    var policy: ConflictChoice?

    var displayName: String { source.name }
    var progress: Double {
        if state == .finished { return 1 }
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
    var remainingSeconds: Double? {
        guard speed > 1_000, bytesDone < bytesTotal else { return nil }
        return Double(bytesTotal - bytesDone) / speed
    }
}

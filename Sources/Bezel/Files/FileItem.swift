import Foundation
import UniformTypeIdentifiers

/// One entry in a directory, from either the Mac or an Android device.
struct FileItem: Identifiable, Hashable, Sendable {
    let backendID: String
    /// Absolute path in the backend's namespace.
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date
    /// POSIX permission string such as `-rw-r--r--` or `drwxr-xr-x`.
    let permissions: String

    var id: String { backendID + "\u{0}" + path }
    var isHidden: Bool { name.hasPrefix(".") }

    var type: UTType {
        if isDirectory { return .folder }
        if isSymlink { return .aliasFile }
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var kind: String {
        if isDirectory { return "Folder" }
        if isSymlink { return "Alias" }
        if name.lowercased().hasSuffix(".apk") { return "Android app" }
        return type.localizedDescription ?? "Document"
    }

    var displaySize: String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayModified: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(modified) {
            return modified.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(modified) {
            return "Yesterday"
        }
        if calendar.component(.year, from: modified) == calendar.component(.year, from: Date()) {
            return modified.formatted(.dateTime.month(.abbreviated).day())
        }
        return modified.formatted(date: .numeric, time: .omitted)
    }

    var displayPermissions: String {
        permissions.isEmpty ? "—" : permissions
    }
}

extension Array where Element == FileItem {
    /// Finder-style name ordering: "IMG 2" comes before "IMG 10".
    func naturalSorted(ascending: Bool = true) -> [FileItem] {
        sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            if result == .orderedSame { return $0.path < $1.path }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}

enum FileSortKey: String, CaseIterable, Sendable, Codable {
    case name = "Name"
    case date = "Date Modified"
    case size = "Size"
    case kind = "Kind"

    var label: String { rawValue }
}

func sortedFiles(_ items: [FileItem], by key: FileSortKey, ascending: Bool) -> [FileItem] {
    func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch key {
        case .name:
            let result = a.name.localizedStandardCompare(b.name)
            if result == .orderedSame { return a.path.compare(b.path) }
            return result
        case .date:
            if a.modified == b.modified { return a.name.localizedStandardCompare(b.name) }
            return a.modified < b.modified ? .orderedAscending : .orderedDescending
        case .size:
            if a.size == b.size { return a.name.localizedStandardCompare(b.name) }
            return a.size < b.size ? .orderedAscending : .orderedDescending
        case .kind:
            let result = a.kind.localizedStandardCompare(b.kind)
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) }
            return result
        }
    }
    return items.sorted { compare($0, $1) == (ascending ? .orderedAscending : .orderedDescending) }
}

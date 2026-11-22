import Foundation
import Testing
@testable import Bezel

@Test func statParsingHandlesSpacesAndPipes() {
    let text = """
    4096|1700000000|41ed|drwxr-xr-x|./My Photos
    12345|1700000001|81a4|-rw-r--r--|./a|b.txt
    0|1700000002|a1ff|lrwxrwxrwx|./link
    """
    let items = ADBBackend.parseStat(text, backendID: "serial", base: "/sdcard/DCIM")
    #expect(items.count == 3)
    #expect(items[0].name == "My Photos")
    #expect(items[0].isDirectory)
    #expect(items[0].size == 0)
    #expect(items[0].path == "/sdcard/DCIM/My Photos")
    #expect(items[1].name == "a|b.txt")
    #expect(items[1].size == 12345)
    #expect(!items[1].isDirectory)
    #expect(items[2].isSymlink)
}

@Test func conflictNamesFollowFinder() {
    #expect(FilePath.conflictName(for: "Report.pdf", attempt: 1) == "Report.pdf")
    #expect(FilePath.conflictName(for: "Report.pdf", attempt: 2) == "Report 2.pdf")
    #expect(FilePath.conflictName(for: "Report", attempt: 3) == "Report 3")
    #expect(FilePath.conflictName(for: "archive.tar.gz", attempt: 2) == "archive.tar 2.gz")
}

@Test func naturalSortPuts2Before10() {
    let names = ["IMG 10.jpg", "IMG 2.jpg", "a.jpg"]
    let items = names.map {
        FileItem(backendID: "local", path: "/\($0)", name: $0,
                 isDirectory: false, isSymlink: false, size: 0,
                 modified: Date.distantPast, permissions: "-rw-r--r--")
    }
    #expect(items.naturalSorted().map(\.name) == ["a.jpg", "IMG 2.jpg", "IMG 10.jpg"])
    #expect(sortedFiles(items, by: .name, ascending: false).map(\.name)
            == ["IMG 10.jpg", "IMG 2.jpg", "a.jpg"])
}

@Test func shellQuoteProtectsSingleQuotes() {
    #expect(shellQuote("plain") == "'plain'")
    #expect(shellQuote("a'b") == "'a'\\''b'")
    #expect(FilePath.join("/sdcard", "DCIM") == "/sdcard/DCIM")
    #expect(FilePath.parent("/sdcard/DCIM/a.jpg") == "/sdcard/DCIM")
    #expect(FilePath.name("/sdcard/DCIM/a.jpg") == "a.jpg")
}

@Test func permissionStringMatchesUnixNotation() {
    #expect(LocalBackend.permissionString(0o644, isDirectory: false) == "-rw-r--r--")
    #expect(LocalBackend.permissionString(0o755, isDirectory: true) == "drwxr-xr-x")
}

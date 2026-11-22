import AppKit
import Foundation
import Testing
@testable import Bezel

@Test @MainActor func transferQueueCopiesFolders() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bezel-queue-test-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let nested = source.appendingPathComponent("nested", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    try "one".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "two".write(to: nested.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

    let local = LocalBackend()
    let folder = try await local.info(source.path)
    #expect(try await local.measure(source.path).files == 2)

    TransferCenter.shared.enqueue(items: [folder], from: local, to: local, directory: destination.path)

    for _ in 0..<60 {
        if TransferCenter.shared.activeCount == 0 { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(TransferCenter.shared.activeCount == 0)
    #expect(try await local.exists(destination.appendingPathComponent("source/a.txt").path))
    #expect(try await local.exists(destination.appendingPathComponent("source/nested/b.txt").path))
    #expect(try String(contentsOf: destination.appendingPathComponent("source/a.txt"), encoding: .utf8) == "one")
}

@Test @MainActor func filesWindowLoadsLocalDirectory() async throws {
    let local = LocalBackend()
    let controller = FilesWindowController(
        backend: local,
        path: NSHomeDirectory(),
        coordinator: FilesCoordinator.shared
    )
    controller.showWindow(nil)
    defer { controller.window?.close() }

    for _ in 0..<40 {
        if !controller.browser.primaryPane.items.isEmpty { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!controller.browser.primaryPane.items.isEmpty)
    #expect(controller.window?.contentViewController === controller.browser)
}

import Foundation
import Testing
@testable import Bezel

/// Run with `BEZEL_TEST_SERIAL=<serial> swift test`. Skips quietly when no
/// device is configured, so `swift test` stays a pure unit run.
@Test func androidBackendRoundTrip() async throws {
    guard let serial = ProcessInfo.processInfo.environment["BEZEL_TEST_SERIAL"] else { return }
    let adb = ADB()
    _ = try await adb.devices()
    let backend = ADBBackend(adb: adb, serial: serial, name: "Test phone")
    let directory = "/sdcard/Download/BezelFilesTest-\(UUID().uuidString)"

    let local = FileManager.default.temporaryDirectory
        .appendingPathComponent("bezel-files-test-\(UUID().uuidString).txt")
    let output = local.deletingLastPathComponent()
        .appendingPathComponent("bezel-files-out-\(UUID().uuidString).txt")
    defer {
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: output)
    }

    do {
        try await backend.makeDirectory(directory)
        try "hello bezel".write(to: local, atomically: true, encoding: .utf8)

        let remote = FilePath.join(directory, "hello.txt")
        try await backend.upload(local, to: remote, onBytes: { _ in })

        let info = try await backend.info(remote)
        #expect(info.size == 11)
        #expect(info.name == "hello.txt")

        let listed = try await backend.list(directory)
        #expect(listed.contains { $0.name == "hello.txt" })

        FileManager.default.createFile(atPath: output.path, contents: nil)
        try await backend.download(remote, to: output, onBytes: { _ in })
        #expect(try String(contentsOf: output, encoding: .utf8) == "hello bezel")

        let unicode = FilePath.join(directory, "foto ünicode")
        try await backend.makeDirectory(unicode)
        try await backend.move(remote, to: FilePath.join(unicode, "moved.txt"))
        #expect(try await backend.exists(FilePath.join(unicode, "moved.txt")))

        let found = try await backend.search("moved", in: directory, deep: true)
        #expect(!found.isEmpty)

        let totals = try await backend.measure(directory)
        #expect(totals.files == 1)
        #expect(totals.bytes == 11)
    } catch {
        try? await backend.delete([directory])
        throw error
    }
    try await backend.delete([directory])
    #expect(try await backend.exists(directory) == false)
}

/// Exercises the real queue: Mac folder → phone → Mac, with folder recursion.
@Test @MainActor func transferCenterRoundTrip() async throws {
    guard let serial = ProcessInfo.processInfo.environment["BEZEL_TEST_SERIAL"] else { return }
    let adb = ADB()
    _ = try await adb.devices()
    let backend = ADBBackend(adb: adb, serial: serial, name: "Test phone")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bezel-transfer-test-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let nested = source.appendingPathComponent("nested", isDirectory: true)
    let back = root.appendingPathComponent("back", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "payload".write(to: nested.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

    let remoteDirectory = "/sdcard/Download/BezelTransferTest-\(UUID().uuidString)"

    func waitForQueue() async throws {
        for _ in 0..<150 {
            if TransferCenter.shared.activeCount == 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    do {
        let local = LocalBackend()
        let folder = try await local.info(source.path)
        TransferCenter.shared.enqueue(items: [folder], from: local, to: backend, directory: remoteDirectory)
        try await waitForQueue()

        let remoteFile = FilePath.join(remoteDirectory, "source/nested/data.txt")
        #expect(try await backend.exists(remoteFile))
        let jobs = TransferCenter.shared.jobs.filter { $0.destinationDirectory == remoteDirectory }
        #expect(jobs.allSatisfy { $0.state == .finished })

        let remoteFolder = try await backend.info(FilePath.join(remoteDirectory, "source"))
        TransferCenter.shared.enqueue(items: [remoteFolder], from: backend, to: local, directory: back.path)
        try await waitForQueue()

        let returned = back.appendingPathComponent("source/nested/data.txt")
        #expect(try String(contentsOf: returned, encoding: .utf8) == "payload")
    } catch {
        try? await backend.delete([remoteDirectory])
        throw error
    }
    // Always await cleanup: a fire-and-forget Task can outlive the test
    // process and leave an undeletable test folder on the device.
    try await backend.delete([remoteDirectory])
    #expect(try await backend.exists(remoteDirectory) == false)
}

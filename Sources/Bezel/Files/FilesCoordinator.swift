import AppKit
import Foundation

struct FileLocation: Identifiable, Hashable, Sendable {
    let backendID: String
    let path: String
    let title: String
    let symbol: String
    var subtitle: String?

    var id: String { backendID + "\u{0}" + path }
}

/// Shared owner of the files windows. The mirror app and the Finder Service
/// both come through here.
@MainActor
final class FilesCoordinator {
    static let shared = FilesCoordinator()

    private(set) var windows: [FilesWindowController] = []
    private var remoteBackends: [String: ADBBackend] = [:]
    private weak var state: AppState?
    private weak var mirrorWindow: NSWindow?
    let local = LocalBackend()
    var lastPhoneDirectory = "/sdcard/Download"
    var statusMessage: String?

    /// Set when the Finder Service fires before the main window has finished launching.
    var pendingSend: [URL]?

    func attach(_ state: AppState) {
        self.state = state
        if mirrorWindow == nil { mirrorWindow = findMirrorWindow() }
        if state.devices.isEmpty { Task { await state.refresh() } }
        if let pendingSend {
            self.pendingSend = nil
            sendToAndroid(pendingSend)
        }
    }

    var devices: [Device] { state?.devices ?? [] }
    var settings: Settings {
        get { state?.settings ?? Settings() }
        set { state?.settings = newValue }
    }

    func device(serial: String) -> Device? {
        devices.first { $0.serial == serial }
    }

    func preferredDevice() -> Device? {
        if let serial = state?.selectedSerial, let device = device(serial: serial), device.isReady {
            return device
        }
        return devices.first(where: \.isReady)
    }

    func backend(for id: String) -> (any FileBackend)? {
        if id == local.id { return local }
        let serial = id.split(separator: ":", maxSplits: 1).map(String.init).first ?? id
        let root = id.contains(":") ? String(id[id.index(after: id.firstIndex(of: ":")!)...]) : "/sdcard"
        guard let state, devices.contains(where: { $0.serial == serial && $0.isReady }) else { return nil }
        if let cached = remoteBackends[id] { return cached }
        let backend = ADBBackend(
            adb: state.adb,
            serial: serial,
            name: device(serial: serial)?.displayName ?? serial,
            root: root
        )
        remoteBackends[id] = backend
        return backend
    }

    func androidBackend(serial: String) -> ADBBackend? {
        backend(for: "\(serial):/sdcard") as? ADBBackend
    }

    /// Internal storage plus any real SD cards the phone reports.
    func androidLocations(serial: String) async -> [FileLocation] {
        var locations = [FileLocation(
            backendID: "\(serial):/sdcard",
            path: "/sdcard",
            title: "Internal storage",
            symbol: "internaldrive"
        )]
        guard let state else { return locations }
        let result = try? await state.adb.captured(["-s", serial, "shell", "ls /storage"])
        let names = String(decoding: result?.stdout ?? Data(), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "emulated" && $0 != "self" }
        for name in names.prefix(4) {
            locations.append(FileLocation(
                backendID: "\(serial):/storage/\(name)",
                path: "/storage/\(name)",
                title: "SD card",
                symbol: "sdcard",
                subtitle: name
            ))
        }
        return locations
    }

    // MARK: - Windows

    func open(backendID: String? = nil, path: String? = nil, asTab: Bool = true) {
        let initialBackend = backendID.flatMap { backend(for: $0) } ?? local
        let settings = state?.settings
        let resolvedPath = path ?? settings?.filesLastPaths[initialBackend.id] ?? initialBackend.defaultPath

        // ⌘B should always come back to the same Files tab. Creating a new
        // window each time filled the mirror window's tab bar with duplicates.
        if asTab, let existing = windows.first(where: { $0.window?.isVisible == true }) {
            if let main = mainMirrorWindow(),
               let filesWindow = existing.window,
               main.tabbedWindows?.contains(filesWindow) != true,
               !main.styleMask.contains(.fullScreen) {
                filesWindow.tabbingIdentifier = main.tabbingIdentifier
                main.addTabbedWindow(filesWindow, ordered: .above)
            }
            existing.window?.makeKeyAndOrderFront(nil)
            if let path {
                existing.browser.primaryPane.navigate(to: initialBackend, path: path)
            }
            setConflictHandler(for: existing)
            return
        }

        let controller = FilesWindowController(
            backend: initialBackend,
            path: resolvedPath,
            coordinator: self
        )
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        if asTab,
           let main = mainMirrorWindow(),
           !main.styleMask.contains(.fullScreen),
           let filesWindow = controller.window {
            // AppKit requires matching identifiers (including both nil) before
            // it will merge a window into another window's tab bar.
            filesWindow.tabbingIdentifier = main.tabbingIdentifier
            main.addTabbedWindow(filesWindow, ordered: .above)
        }

        setConflictHandler(for: controller)
    }

    private func setConflictHandler(for controller: FilesWindowController) {
        TransferCenter.shared.conflictHandler = { [weak controller] conflict in
            await controller?.resolve(conflict) ?? (.keepBoth, false)
        }
    }

    func windowDidClose(_ controller: FilesWindowController) {
        windows.removeAll { $0 === controller }
    }

    func activeWindow() -> FilesWindowController? {
        if let key = NSApp.keyWindow?.windowController as? FilesWindowController { return key }
        return windows.first { $0.window?.isVisible == true }
    }

    /// Never key off the window title: once Files is the selected tab, the
    /// shared window is titled "Files" and looking for "Bezel" creates another
    /// Files window on every ⌘B.
    private func mainMirrorWindow() -> NSWindow? {
        if let mirrorWindow, mirrorWindow.isVisible { return mirrorWindow }
        mirrorWindow = findMirrorWindow()
        return mirrorWindow
    }

    private func findMirrorWindow() -> NSWindow? {
        NSApp.windows.first {
            !($0.windowController is FilesWindowController)
                && $0.frame.width > 800
                && $0.contentView != nil
        }
    }

    // MARK: - Drop on the mirror / Finder Service

    func sendToAndroid(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard state != nil else {
            pendingSend = urls
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let device = preferredDevice(), let backend = androidBackend(serial: device.serial) else {
            state?.showToast("Connect an Android device first")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var items: [FileItem] = []
            for url in urls {
                if let item = try? await local.info(url.path) { items.append(item) }
            }
            guard !items.isEmpty else { return }
            TransferCenter.shared.enqueue(
                items: items,
                from: local,
                to: backend,
                directory: lastPhoneDirectory
            )
            state?.showToast("Sending \(items.count) item\(items.count == 1 ? "" : "s") to \(device.displayName)")
            open(backendID: backend.id, path: lastPhoneDirectory, asTab: true)
        }
    }

    func notePath(_ path: String, backendID: String) {
        guard let state, state.settings.filesLastPaths[backendID] != path else { return }
        state.settings.filesLastPaths[backendID] = path
        state.settings.save()
    }
}

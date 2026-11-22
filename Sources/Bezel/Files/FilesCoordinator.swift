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

    private(set) var files: FilesTabController?
    /// Mirror or Files tab in the shared window; set by `RootView`.
    var filesTabIsVisible = false
    private var detachedWindows: [NSWindow] = []
    private var remoteBackends: [String: ADBBackend] = [:]
    private weak var state: AppState?
    let local = LocalBackend()
    var lastPhoneDirectory = "/sdcard/Download"
    var statusMessage: String?

    /// Set when the Finder Service fires before the main window has finished launching.
    var pendingSend: [URL]?

    func attach(_ state: AppState) {
        self.state = state
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

    // MARK: - Files tab

    /// The Files browser is a tab inside the single Bezel window, so ⌘B only
    /// switches to it. It never creates or moves a window.
    func showFiles(backendID: String? = nil, path: String? = nil, asTab: Bool = true) {
        if asTab {
            let tab = filesTab(backendID: backendID, path: path)
            if let backendID, let path, let backend = backend(for: backendID) {
                tab.browser.primaryPane.navigate(to: backend, path: path, recordHistory: false)
            }
            NotificationCenter.default.post(name: .bezelShowFiles, object: nil)
        } else {
            detachedWindows.removeAll { !$0.isVisible }
            let tab = makeFiles(backendID: backendID, path: path)
            let window = NSWindow(contentViewController: tab)
            window.title = "Files"
            window.contentMinSize = NSSize(width: 760, height: 460)
            window.setContentSize(NSSize(width: 1080, height: 700))
            window.tabbingMode = .disallowed
            window.center()
            detachedWindows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @discardableResult
    func filesTab(backendID: String? = nil, path: String? = nil) -> FilesTabController {
        if let files { return files }
        let tab = makeFiles(backendID: backendID, path: path)
        files = tab
        return tab
    }

    private func makeFiles(backendID: String?, path: String?) -> FilesTabController {
        let initialBackend = backendID.flatMap { backend(for: $0) } ?? local
        let resolvedPath = path ?? settings.filesLastPaths[initialBackend.id] ?? initialBackend.defaultPath
        let tab = FilesTabController(backend: initialBackend, path: resolvedPath, coordinator: self)
        TransferCenter.shared.conflictHandler = { [weak tab] conflict in
            await tab?.resolve(conflict) ?? (.keepBoth, false)
        }
        return tab
    }

    /// Menu commands act on the key Files window when one is detached,
    /// otherwise on the in-window Files tab.
    func activeFiles() -> FilesTabController? {
        if let key = NSApp.keyWindow?.contentViewController as? FilesTabController { return key }
        return filesTabIsVisible ? files : nil
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
            showFiles(backendID: backend.id, path: lastPhoneDirectory)
        }
    }

    func notePath(_ path: String, backendID: String) {
        guard let state, state.settings.filesLastPaths[backendID] != path else { return }
        state.settings.filesLastPaths[backendID] = path
        state.settings.save()
    }
}

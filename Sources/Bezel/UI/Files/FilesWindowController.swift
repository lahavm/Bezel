import AppKit
import QuickLookUI

final class QuickLookContext: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        urls[index] as NSURL
    }
}

private final class TransferRow: NSTableCellView {
    let bar = NSProgressIndicator()
    let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(detail)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: 8),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }
}

@MainActor
final class TransfersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private lazy var cancelAll: NSButton = {
        let button = NSButton(title: "Cancel All", target: self, action: #selector(cancelAllTapped))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    @objc private func cancelAllTapped() {
        TransferCenter.shared.cancelAll()
        reload()
    }
    private var snapshot: [TransferJob] = []
    private var timer: Timer?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 260))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = "File"
        column.width = 150
        let progress = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Progress"))
        progress.title = "Progress"
        progress.width = 210
        table.addTableColumn(column)
        table.addTableColumn(progress)
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.headerView = nil

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(cancelAll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: cancelAll.topAnchor, constant: -8),
            cancelAll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            cancelAll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reload()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        snapshot = TransferCenter.shared.jobs.reversed()
        table.reloadData()
        cancelAll.isEnabled = TransferCenter.shared.activeCount > 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let job = snapshot[row]
        let identifier = column?.identifier ?? NSUserInterfaceItemIdentifier("Name")
        if identifier.rawValue == "Name" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = job.displayName
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            return cell
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TransferRow ?? TransferRow()
        cell.identifier = identifier
        cell.bar.doubleValue = job.progress * 100
        cell.bar.isIndeterminate = job.state == .preparing
        if cell.bar.isIndeterminate { cell.bar.startAnimation(nil) } else { cell.bar.stopAnimation(nil) }
        if let remaining = job.remainingSeconds {
            cell.detail.stringValue = "\(Int(job.speed / 1_048_576)) MB/s · \(Int(remaining))s left"
        } else if let message = job.message {
            cell.detail.stringValue = message
        } else {
            cell.detail.stringValue = job.state.rawValue.capitalized
        }
        return cell
    }
}

@MainActor
final class FilesWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let browser: FilesBrowserController
    private let coordinator: FilesCoordinator
    private let transfers = TransfersViewController()
    private let popover = NSPopover()
    private var quickLookContext: QuickLookContext?
    private var transferButton: NSButton!

    init(backend: any FileBackend, path: String, coordinator: FilesCoordinator) {
        self.coordinator = coordinator
        self.browser = FilesBrowserController(backend: backend, path: path)
        super.init(window: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Files"
        window.minSize = NSSize(width: 760, height: 460)
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "com.lahav.bezel.files"
        window.setFrameAutosaveName("BezelFiles")
        window.delegate = self
        self.window = window

        browser.windowController = self
        window.contentViewController = browser

        let toolbar = NSToolbar(identifier: "BezelFilesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        popover.contentViewController = transfers
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 260)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    func windowWillClose(_ notification: Notification) {
        coordinator.windowDidClose(self)
    }

    // MARK: - Toolbar

    private func id(_ name: String) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(name)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [id("backForward"), id("viewMode"), id("sort"), id("newFolder"), id("transfers"),
         id("search"), id("more"), .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [id("backForward"), id("viewMode"), id("sort"), id("newFolder"), .flexibleSpace,
         id("transfers"), id("search"), id("more")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "backForward":
            let control = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(goBackForward(_:))
            )
            control.setWidth(34, forSegment: 0)
            control.setWidth(34, forSegment: 1)
            return item(itemIdentifier, title: "History", view: control)
        case "viewMode":
            let control = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                    NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!
                ],
                trackingMode: .selectOne,
                target: self,
                action: #selector(viewModeChanged(_:))
            )
            control.setWidth(34, forSegment: 0)
            control.setWidth(34, forSegment: 1)
            control.selectedSegment = coordinator.settings.filesViewMode == .list ? 1 : 0
            return item(itemIdentifier, title: "View", view: control)
        case "sort":
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24), pullsDown: true)
            pop.addItems(withTitles: FileSortKey.allCases.map(\.label))
            pop.selectItem(at: FileSortKey.allCases.firstIndex(of: coordinator.settings.filesSortKey) ?? 0)
            pop.target = self
            pop.action = #selector(sortChanged(_:))
            return item(itemIdentifier, title: "Sort", view: pop)
        case "newFolder":
            let button = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")!,
                                  target: self, action: #selector(newFolder(_:)))
            button.bezelStyle = .texturedRounded
            return item(itemIdentifier, title: "New Folder", view: button)
        case "transfers":
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Transfers")!,
                                  target: self, action: #selector(showTransfers(_:)))
            button.bezelStyle = .texturedRounded
            transferButton = button
            NotificationCenter.default.addObserver(
                forName: .bezelTransfersChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateTransferButton() }
            }
            return item(itemIdentifier, title: "Transfers", view: button)
        case "search":
            let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
            field.placeholderString = "Search"
            field.delegate = self
            field.target = self
            field.action = #selector(searchChanged(_:))
            return item(itemIdentifier, title: "Search", view: field)
        case "more":
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24), pullsDown: true)
            let menu = NSMenu()
            let options = [
                ("Split Panes", #selector(toggleSplit)),
                ("Show Preview", #selector(togglePreview)),
                ("Show Hidden Files", #selector(toggleHidden)),
                ("Refresh", #selector(refresh)),
                ("Files in New Window", #selector(newWindow))
            ]
            for (index, option) in options.enumerated() {
                let menuItem = NSMenuItem(title: option.0, action: option.1, keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = index
                menu.addItem(menuItem)
            }
            pop.menu = menu
            pop.bezelStyle = .texturedRounded
            return item(itemIdentifier, title: "More", view: pop)
        default:
            return nil
        }
    }

    private func item(_ identifier: NSToolbarItem.Identifier, title: String, view: NSView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.view = view
        item.minSize = NSSize(width: 28, height: 24)
        return item
    }

    // MARK: - Toolbar actions

    @objc private func goBackForward(_ control: NSSegmentedControl) {
        if control.selectedSegment == 0 { browser.activePane.goBack() } else { browser.activePane.goForward() }
    }

    @objc private func viewModeChanged(_ control: NSSegmentedControl) {
        coordinator.settings.filesViewMode = control.selectedSegment == 1 ? .list : .icons
        coordinator.settings.save()
        browser.primaryPane.applyViewMode()
        browser.secondaryPane?.applyViewMode()
    }

    @objc private func sortChanged(_ pop: NSPopUpButton) {
        let index = pop.indexOfSelectedItem
        guard index >= 0, index < FileSortKey.allCases.count else { return }
        coordinator.settings.filesSortKey = FileSortKey.allCases[index]
        coordinator.settings.save()
        browser.refreshAll()
    }

    @objc private func newFolder(_ sender: Any) { browser.activePane.newFolder() }
    @objc private func refresh(_ sender: Any) { browser.refreshAll() }

    @objc private func searchChanged(_ field: NSSearchField) {
        browser.activePane.setSearch(field.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        browser.activePane.setSearch(field.stringValue)
    }

    private func updateTransferButton() {
        let active = TransferCenter.shared.activeCount
        transferButton?.contentTintColor = active > 0 ? .controlAccentColor : nil
        transferButton?.toolTip = active > 0 ? "\(active) transfer\(active == 1 ? "" : "s") in progress" : "Transfers"
    }

    @objc private func showTransfers(_ sender: NSButton) {
        transfers.reload()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func toggleSplit() { browser.setSplit(!coordinator.settings.filesSplit) }
    @objc private func togglePreview() { browser.setPreview(!coordinator.settings.filesShowPreview) }
    @objc private func toggleHidden() {
        coordinator.settings.filesShowHidden.toggle()
        coordinator.settings.save()
        browser.refreshAll()
    }

    @objc private func newWindow() {
        coordinator.open(
            backendID: browser.activePane.backend.id,
            path: browser.activePane.path,
            asTab: false
        )
    }

    // MARK: - Conflict sheet

    func resolve(_ conflict: FileConflict) async -> (ConflictChoice, Bool) {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(conflict.name)” already exists"
            alert.informativeText = "Choose what to do with the file already in the destination folder."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Skip")
            let checkbox = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
            alert.accessoryView = checkbox
            guard let window else {
                continuation.resume(returning: (.keepBoth, false))
                return
            }
            alert.beginSheetModal(for: window) { response in
                let choice: ConflictChoice
                switch response {
                case .alertFirstButtonReturn: choice = .replace
                case .alertSecondButtonReturn: choice = .keepBoth
                default: choice = .skip
                }
                continuation.resume(returning: (choice, checkbox.state == .on))
            }
        }
    }

    // MARK: - Quick Look

    func quickLook(_ items: [FileItem], backend: any FileBackend) {
        guard !items.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var urls: [URL] = []
            for item in items.prefix(8) {
                if backend.isRemote {
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent("bezel-quicklook-\(UUID().uuidString)-\(item.name)")
                    do {
                        FileManager.default.createFile(atPath: temporary.path, contents: nil)
                        try await backend.download(item.path, to: temporary, onBytes: { _ in })
                        urls.append(temporary)
                    } catch {
                        coordinator.statusMessage = error.localizedDescription
                    }
                } else {
                    urls.append(URL(fileURLWithPath: item.path))
                }
            }
            guard !urls.isEmpty else { return }
            let context = QuickLookContext(urls: urls)
            self.quickLookContext = context
            let panel = QLPreviewPanel.shared()!
            panel.dataSource = context
            panel.delegate = context
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Menu forwarding

    func newFolder() { browser.activePane.newFolder() }
    func rename() { browser.activePane.rename() }
    func delete() { browser.activePane.deleteSelection() }
    func quickLookSelection() { browser.activePane.quickLook() }
    func toggleHiddenFiles() { toggleHidden() }
    func togglePreviewPane() { togglePreview() }
    func toggleSplitView() { toggleSplit() }
    func refreshPanes() { browser.refreshAll() }
}

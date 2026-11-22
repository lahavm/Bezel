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

/// The Files tab: a compact control row plus the browser. It lives inside the
/// single Bezel window, so no window tabbing (and no window jumping) is needed.
@MainActor
final class FilesTabController: NSViewController, NSSearchFieldDelegate {
    let browser: FilesBrowserController
    private let coordinator: FilesCoordinator
    private let transfers = TransfersViewController()
    private let popover = NSPopover()
    private var quickLookContext: QuickLookContext?

    private var backForward: NSSegmentedControl!
    private var viewMode: NSSegmentedControl!
    private var sortPop: NSPopUpButton!
    private var searchField: NSSearchField!
    private var transferButton: NSButton!

    init(backend: any FileBackend, path: String, coordinator: FilesCoordinator) {
        self.coordinator = coordinator
        self.browser = FilesBrowserController(backend: backend, path: path)
        super.init(nibName: nil, bundle: nil)
        browser.windowController = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 700))
        let header = makeHeader()

        addChild(browser)
        let content = browser.view
        content.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(content)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),

            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container

        popover.contentViewController = transfers
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 260)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        backForward = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(goBackForward(_:))
        )
        backForward.setWidth(30, forSegment: 0)
        backForward.setWidth(30, forSegment: 1)

        viewMode = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(viewModeChanged(_:))
        )
        viewMode.setWidth(30, forSegment: 0)
        viewMode.setWidth(30, forSegment: 1)

        sortPop = NSPopUpButton(frame: .zero, pullsDown: false)
        sortPop.addItems(withTitles: FileSortKey.allCases.map(\.label))
        sortPop.target = self
        sortPop.action = #selector(sortChanged(_:))
        sortPop.translatesAutoresizingMaskIntoConstraints = false

        let newFolder = NSButton(
            image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")!,
            target: self,
            action: #selector(newFolder(_:))
        )
        newFolder.bezelStyle = .rounded
        newFolder.toolTip = "New Folder"

        transferButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Transfers")!,
            target: self,
            action: #selector(showTransfers(_:))
        )
        transferButton.bezelStyle = .rounded
        transferButton.toolTip = "Transfers"
        NotificationCenter.default.addObserver(
            forName: .bezelTransfersChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTransferButton() }
        }

        searchField = NSSearchField()
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")!,
            target: self,
            action: #selector(showMore(_:))
        )
        more.bezelStyle = .rounded
        more.toolTip = "More"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            backForward, viewMode, sortPop, newFolder,
            spacer, transferButton, searchField, more
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        header.addSubview(line)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.topAnchor),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -1),

            searchField.widthAnchor.constraint(equalToConstant: 180),
            sortPop.widthAnchor.constraint(equalToConstant: 120),

            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return header
    }

    private func syncControls() {
        viewMode.selectedSegment = coordinator.settings.filesViewMode == .list ? 1 : 0
        if let index = FileSortKey.allCases.firstIndex(of: coordinator.settings.filesSortKey) {
            sortPop.selectItem(at: index)
        }
        updateTransferButton()
    }

    private func updateTransferButton() {
        let active = TransferCenter.shared.activeCount
        transferButton?.contentTintColor = active > 0 ? .controlAccentColor : nil
        transferButton?.toolTip = active > 0 ? "\(active) transfer\(active == 1 ? "" : "s") in progress" : "Transfers"
    }

    // MARK: - Actions

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

    @objc private func showTransfers(_ sender: NSButton) {
        transfers.reload()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        let options: [(String, Selector, Bool)] = [
            ("Split Panes", #selector(toggleSplit), coordinator.settings.filesSplit),
            ("Show Preview", #selector(togglePreview), coordinator.settings.filesShowPreview),
            ("Show Hidden Files", #selector(toggleHidden), coordinator.settings.filesShowHidden)
        ]
        for (title, action, on) in options {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let newWindow = NSMenuItem(title: "Files in New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func toggleSplit() { browser.setSplit(!coordinator.settings.filesSplit) }
    @objc private func togglePreview() { browser.setPreview(!coordinator.settings.filesShowPreview) }
    @objc private func toggleHidden() {
        coordinator.settings.filesShowHidden.toggle()
        coordinator.settings.save()
        browser.refreshAll()
    }

    @objc private func newWindow(_ sender: Any) {
        coordinator.showFiles(
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
            guard let window = view.window else {
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

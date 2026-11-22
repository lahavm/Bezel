import AppKit
import UniformTypeIdentifiers

private extension NSPasteboard.PasteboardType {
    static let bezelFileRef = NSPasteboard.PasteboardType("com.lahav.bezel.file-ref")
}

/// Handed to our own drop targets so a drag never materializes the file first.
@MainActor
enum FilesDragSession {
    static var backendID: String?
    static var paths: [String]?
}

final class DropTableView: NSTableView {
    var onCanDrop: ((NSDraggingInfo) -> Bool)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var onActivate: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onActivate?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onCanDrop?(sender) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onCanDrop?(sender) == true ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender) ?? false
    }
}

final class DoubleClickCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    var onCanDrop: ((NSDraggingInfo) -> Bool)?
    var onDrop: ((NSDraggingInfo) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let path = indexPathForItem(at: point) {
                onDoubleClick?(path)
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onCanDrop?(sender) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onCanDrop?(sender) == true ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender) ?? false
    }
}

final class FileIconItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let label = NSTextField()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 108))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -2)
        ])
        view = container
    }

    func configure(with item: FileItem, backend: any FileBackend) {
        _ = view
        label.stringValue = item.name
        icon.image = NSWorkspace.shared.icon(for: item.type)
        if item.type.conforms(to: .image) || item.type.conforms(to: .pdf) {
            Task { @MainActor in
                guard let image = await ThumbnailCache.shared.image(for: item, backend: backend) else { return }
                self.icon.image = image
            }
        }
    }
}

/// One independent Finder-like pane: path bar, content, status bar.
@MainActor
final class FilePaneViewController: NSViewController {
    weak var browser: FilesBrowserController?

    var backend: any FileBackend
    var path: String {
        didSet { FilesCoordinator.shared.notePath(path, backendID: backend.id) }
    }

    private(set) var items: [FileItem] = []
    private var selectedIDs: Set<String> = []
    private var searchQuery = ""
    private var loadGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var freeText = ""
    private var renamingRow: Int?

    private var history: [(backendID: String, path: String)] = []
    private var historyIndex = -1

    private let pathBar = PathBar()
    private let listView = DropTableView()
    private let iconView = DoubleClickCollectionView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let contextMenu = NSMenu()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))

    init(backend: any FileBackend, path: String) {
        self.backend = backend
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    var displayItems: [FileItem] {
        let settings = FilesCoordinator.shared.settings
        let visible = settings.filesShowHidden ? items : items.filter { !$0.isHidden }
        return sortedFiles(visible, by: settings.filesSortKey, ascending: settings.filesSortAscending)
    }

    var selectedItems: [FileItem] {
        displayItems.filter { selectedIDs.contains($0.id) }
    }

    var currentTitle: String { searchQuery.isEmpty ? FilePath.name(path) : "Search" }

    // MARK: - View

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))

        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.onSelect = { [weak self] index in self?.selectPathComponent(index) }

        listView.style = .plain
        listView.rowHeight = 24
        listView.usesAlternatingRowBackgroundColors = false
        listView.allowsMultipleSelection = true
        listView.allowsEmptySelection = true
        listView.dataSource = self
        listView.delegate = self
        listView.target = self
        listView.doubleAction = #selector(openDoubleClicked(_:))
        listView.onCanDrop = { [weak self] in self?.canAccept($0) ?? false }
        listView.onDrop = { [weak self] in self?.acceptDrop($0, row: nil) ?? false }
        listView.onActivate = { [weak self] in self?.browser?.activate(pane: self!) }
        listView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        listView.menu = contextMenu
        contextMenu.delegate = self

        nameColumn.title = "Name"
        nameColumn.width = 320
        nameColumn.minWidth = 140
        listView.addTableColumn(nameColumn)
        for (title, width) in [("Date Modified", 140), ("Size", 90), ("Kind", 110)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 60
            listView.addTableColumn(column)
        }

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 108)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        iconView.collectionViewLayout = layout
        iconView.dataSource = self
        iconView.delegate = self
        iconView.allowsMultipleSelection = true
        iconView.allowsEmptySelection = true
        iconView.backgroundColors = [.controlBackgroundColor]
        iconView.onDoubleClick = { [weak self] indexPath in self?.openIcon(at: indexPath) }
        iconView.onCanDrop = { [weak self] in self?.canAccept($0) ?? false }
        iconView.onDrop = { [weak self] in self?.acceptDrop($0, row: nil) ?? false }
        iconView.registerForDraggedTypes([.fileURL])
        iconView.menu = contextMenu
        listView.registerForDraggedTypes([.fileURL])

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = listView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false

        [pathBar, scrollView, line, statusLabel].forEach { container.addSubview($0) }
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: container.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: line.topAnchor),

            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 24)
        ])

        view = container
        applyViewMode()
        navigate(to: backend, path: path, recordHistory: false)
        observeTransfers()
    }

    private func observeTransfers() {
        NotificationCenter.default.addObserver(
            forName: .bezelTransfersChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recentlyFinished = TransferCenter.shared.jobs.contains {
                    !$0.state.isActive && ($0.finished?.timeIntervalSinceNow ?? -100) > -2
                }
                if recentlyFinished { self.load() }
            }
        }
    }

    // MARK: - Navigation

    func navigate(to newBackend: any FileBackend, path newPath: String, recordHistory: Bool = true) {
        if recordHistory {
            let current = (backendID: backend.id, path: path)
            if historyIndex < 0 || history[historyIndex] != current {
                if historyIndex < history.count - 1 {
                    history.removeSubrange((historyIndex + 1)...)
                }
                history.append(current)
                historyIndex = history.count - 1
            }
        }
        backend = newBackend
        path = newPath
        searchQuery = ""
        selectedIDs.removeAll()
        load()
    }

    func navigate(path newPath: String) {
        navigate(to: backend, path: newPath)
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        let entry = history[historyIndex]
        if let target = FilesCoordinator.shared.backend(for: entry.backendID) {
            navigate(to: target, path: entry.path, recordHistory: false)
        }
    }

    func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        let entry = history[historyIndex]
        if let target = FilesCoordinator.shared.backend(for: entry.backendID) {
            navigate(to: target, path: entry.path, recordHistory: false)
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func goUp() {
        guard let parent = FilePath.parent(path) else { return }
        navigate(path: parent)
    }

    private func selectPathComponent(_ index: Int) {
        let root = backend.isRemote ? (backend as? ADBBackend)?.root ?? "/sdcard" : "/"
        if index == 0 {
            navigate(path: root)
            return
        }
        let components = FilePath.components(path, root: root)
        guard index <= components.count else { return }
        navigate(path: FilePath.join(root, components.prefix(index).joined(separator: "/")))
    }

    private func updatePathBar() {
        let root = backend.isRemote ? (backend as? ADBBackend)?.root ?? "/sdcard" : "/"
        let title = backend.isRemote ? backend.name : "This Mac"
        let parts = [title] + FilePath.components(path, root: root)
        pathBar.set(components: parts, symbol: backend.isRemote ? "iphone.gen3" : "laptopcomputer")
    }

    // MARK: - Loading

    func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let query = searchQuery
        let currentPath = path
        let currentBackend = backend
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let found: [FileItem]
                if query.isEmpty {
                    found = try await currentBackend.list(currentPath)
                } else {
                    found = try await currentBackend.search(query, in: currentPath, deep: true)
                }
                guard generation == loadGeneration else { return }
                items = found
                selectedIDs = selectedIDs.filter { id in found.contains { $0.id == id } }
                if let remote = currentBackend as? ADBBackend {
                    freeText = await remote.capacity(at: currentPath).map { Self.spaceString($0.free) } ?? ""
                } else {
                    freeText = currentBackend.freeSpace(at: currentPath).map { Self.spaceString($0.free) } ?? ""
                }
                reloadContent()
                updatePathBar()
                updateStatus()
                browser?.selectionChanged()
            } catch {
                guard generation == loadGeneration else { return }
                items = []
                reloadContent()
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private static func spaceString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " available"
    }

    private func updateStatus() {
        let count = displayItems.count
        let noun = count == 1 ? "item" : "items"
        let prefix = searchQuery.isEmpty ? "\(count) \(noun)" : "\(count) result\(count == 1 ? "" : "s") for “\(searchQuery)”"
        statusLabel.stringValue = freeText.isEmpty ? prefix : "\(prefix) · \(freeText)"
    }

    func setSearch(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, searchQuery == query else { return }
            load()
        }
    }

    func clearSearch() {
        guard !searchQuery.isEmpty else { return }
        searchQuery = ""
        load()
    }

    // MARK: - View modes

    func applyViewMode() {
        let mode = FilesCoordinator.shared.settings.filesViewMode
        scrollView.documentView = mode == .list ? listView : iconView
        if mode == .icons { iconView.reloadData() } else { listView.reloadData() }
    }

    private func reloadContent() {
        applyViewMode()
        if FilesCoordinator.shared.settings.filesViewMode == .icons {
            iconView.reloadData()
        } else {
            listView.reloadData()
        }
        updateStatus()
    }

    // MARK: - Actions

    @objc private func openDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < displayItems.count else { return }
        open(displayItems[row])
    }

    private func openIcon(at indexPath: IndexPath) {
        guard indexPath.item < displayItems.count else { return }
        open(displayItems[indexPath.item])
    }

    func open(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: backend, path: item.path)
            return
        }
        if backend.isRemote {
            browser?.windowController?.quickLook([item], backend: backend)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
    }

    func selectSingle() -> FileItem? { selectedItems.count == 1 ? selectedItems[0] : nil }

    func newFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "untitled folder"
        alert.accessoryView = field
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            Task {
                do {
                    let target = FilePath.join(self.path, name)
                    try await self.backend.makeDirectory(target)
                    self.load()
                } catch { self.showError(error) }
            }
        }
    }

    func rename() {
        guard let item = selectSingle(),
              FilesCoordinator.shared.settings.filesViewMode == .list,
              let row = displayItems.firstIndex(where: { $0.id == item.id }) else {
            renameViaSheet()
            return
        }
        renamingRow = row
        listView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        listView.editColumn(0, row: row, with: nil, select: true)
    }

    private func renameViaSheet() {
        guard let item = selectSingle() else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(item.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != item.name else { return }
            Task {
                do {
                    let parent = FilePath.parent(item.path) ?? self.path
                    try await self.backend.move(item.path, to: FilePath.join(parent, newName))
                    self.load()
                } catch { self.showError(error) }
            }
        }
    }

    func duplicate() {
        guard let item = selectSingle() else { return }
        Task {
            do {
                let parent = FilePath.parent(item.path) ?? path
                var attempt = 2
                var target = ""
                repeat {
                    target = FilePath.join(parent, FilePath.conflictName(for: item.name, attempt: attempt))
                    attempt += 1
                } while try await backend.exists(target)
                try await backend.copy(item.path, to: target)
                load()
            } catch { showError(error) }
        }
    }

    func deleteSelection() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        let permanently = backend.isRemote
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selected.count == 1
            ? "Delete “\(selected[0].name)”?"
            : "Delete \(selected.count) items?"
        alert.informativeText = permanently
            ? "This permanently removes them from the device. This can’t be undone."
            : "They will be moved to the Trash."
        alert.addButton(withTitle: permanently ? "Delete" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                do {
                    try await self.backend.delete(selected.map(\.path))
                    self.load()
                } catch { self.showError(error) }
            }
        }
    }

    func copyPath() {
        guard let item = selectSingle() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    func revealInFinder() {
        guard let item = selectSingle(), !backend.isRemote else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func quickLook() {
        browser?.windowController?.quickLook(selectedItems, backend: backend)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t complete the operation"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    // MARK: - Keyboard

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36: // Return
            if let item = selectSingle() { open(item) }
            return true
        case 49: // Space
            quickLook()
            return true
        case 51, 117: // Delete / Forward delete
            deleteSelection()
            return true
        case 53: // Escape
            clearSearch()
            return true
        default:
            if event.modifierFlags.contains(.command), event.keyCode == 126 {
                goUp()
                return true
            }
            return false
        }
    }
}

// MARK: - NSTableView

extension FilePaneViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { displayItems.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayItems.count else { return nil }
        let item = displayItems[row]
        let identifier = column?.identifier ?? NSUserInterfaceItemIdentifier("Name")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        switch identifier.rawValue {
        case "Name":
            cell.textField?.stringValue = item.name
            let image = NSWorkspace.shared.icon(for: item.type)
            image.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = image
            cell.textField?.isEditable = row == renamingRow
            cell.textField?.delegate = self
            cell.textField?.target = self
            cell.textField?.action = #selector(renameFieldDone(_:))
        case "Date Modified":
            cell.textField?.stringValue = item.displayModified
            cell.imageView?.image = nil
        case "Size":
            cell.textField?.stringValue = item.displaySize
            cell.imageView?.image = nil
        case "Kind":
            cell.textField?.stringValue = item.kind
            cell.imageView?.image = nil
        default:
            break
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)
        if identifier.rawValue == "Name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.imageView = image
            cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4)
            ])
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === listView else { return }
        selectedIDs = indexSetToIDs(table.selectedRowIndexes)
        browser?.selectionChanged()
    }

    private func indexSetToIDs(_ indexes: IndexSet) -> Set<String> {
        Set(indexes.compactMap { $0 < displayItems.count ? displayItems[$0].id : nil })
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < displayItems.count else { return nil }
        let item = displayItems[row]
        let selected = selectedItems.contains(item) ? selectedItems : [item]
        FilesDragSession.backendID = backend.id
        FilesDragSession.paths = selected.map(\.path)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if FilesDragSession.paths == selected.map(\.path) {
                FilesDragSession.paths = nil
                FilesDragSession.backendID = nil
            }
        }
        if backend.isRemote {
            let provider = FilePromiseProvider(
                fileType: item.type.identifier,
                delegate: self
            )
            provider.item = item
            provider.backend = backend
            return provider
        }
        return NSURL(fileURLWithPath: item.path)
    }

    private final class FilePromiseProvider: NSFilePromiseProvider {
        var item: FileItem?
        var backend: (any FileBackend)?
    }
}

extension FilePaneViewController: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? FilePromiseProvider)?.item?.name ?? "Untitled"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let provider = filePromiseProvider as? FilePromiseProvider,
              let item = provider.item else {
            completionHandler(FileError.failed("Nothing to copy."))
            return
        }
        guard let backend = provider.backend else {
            completionHandler(FileError.failed("The source is no longer available."))
            return
        }
        Task { @MainActor in
            do {
                try await self.downloadTree(item, to: url, backend: backend)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    private func downloadTree(_ item: FileItem, to url: URL, backend: any FileBackend) async throws {
        let manager = FileManager.default
        if item.isDirectory {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            for child in try await backend.list(item.path) {
                try await downloadTree(child, to: url.appendingPathComponent(child.name), backend: backend)
            }
        } else {
            manager.createFile(atPath: url.path, contents: nil)
            try await backend.download(item.path, to: url, onBytes: { _ in })
        }
    }
}

// MARK: - Icons

extension FilePaneViewController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = FileIconItem()
        item.configure(with: displayItems[indexPath.item], backend: backend)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectedIDs = Set(indexPaths.compactMap { $0.item < displayItems.count ? displayItems[$0.item].id : nil })
        browser?.selectionChanged()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard indexPath.item < displayItems.count else { return nil }
        let item = displayItems[indexPath.item]
        FilesDragSession.backendID = backend.id
        FilesDragSession.paths = [item.path]
        if backend.isRemote {
            let provider = FilePromiseProvider(
                fileType: item.type.identifier,
                delegate: self
            )
            provider.item = item
            provider.backend = backend
            return provider
        }
        return NSURL(fileURLWithPath: item.path)
    }
}

// MARK: - Context menu and drops

extension FilePaneViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hasSelection = !selectedItems.isEmpty
        menu.addItem(withTitle: backend.isRemote ? "Quick Look" : "Open",
                     action: #selector(menuOpen), keyEquivalent: "\r").target = self
        menu.addItem(withTitle: "Quick Look", action: #selector(menuQuickLook), keyEquivalent: " ").target = self
        menu.addItem(NSMenuItem.separator())
        let rename = menu.addItem(withTitle: "Rename", action: #selector(menuRename), keyEquivalent: "")
        rename.target = self
        rename.isEnabled = selectedItems.count == 1
        let duplicate = menu.addItem(withTitle: "Duplicate", action: #selector(menuDuplicate), keyEquivalent: "")
        duplicate.target = self
        duplicate.isEnabled = selectedItems.count == 1
        menu.addItem(NSMenuItem.separator())
        let delete = menu.addItem(withTitle: backend.isRemote ? "Delete" : "Move to Trash",
                                  action: #selector(menuDelete), keyEquivalent: "\u{8}")
        delete.target = self
        delete.isEnabled = hasSelection
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "New Folder", action: #selector(menuNewFolder), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r")
            .target = self
        menu.addItem(NSMenuItem.separator())
        let copyPath = menu.addItem(withTitle: "Copy Path", action: #selector(menuCopyPath), keyEquivalent: "")
        copyPath.target = self
        copyPath.isEnabled = selectedItems.count == 1
        if !backend.isRemote {
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(menuReveal), keyEquivalent: "")
                .target = self
        }
    }

    @objc private func menuOpen() { if let item = selectSingle() { open(item) } }
    @objc private func menuQuickLook() { quickLook() }
    @objc private func menuRename() { rename() }
    @objc private func menuDuplicate() { duplicate() }
    @objc private func menuDelete() { deleteSelection() }
    @objc private func menuNewFolder() { newFolder() }
    @objc private func menuRefresh() { load() }
    @objc private func menuCopyPath() { copyPath() }
    @objc private func menuReveal() { revealInFinder() }

    func canAccept(_ info: NSDraggingInfo) -> Bool {
        if FilesDragSession.paths != nil { return true }
        return info.draggingPasteboard.types?.contains(.fileURL) == true
    }

    func acceptDrop(_ info: NSDraggingInfo, row: Int?) -> Bool {
        var target = path
        if let row, row < displayItems.count, displayItems[row].isDirectory {
            target = displayItems[row].path
        }
        if let sourceID = FilesDragSession.backendID,
           let paths = FilesDragSession.paths,
           let source = FilesCoordinator.shared.backend(for: sourceID) {
            FilesDragSession.paths = nil
            FilesDragSession.backendID = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                var dragged: [FileItem] = []
                for itemPath in paths {
                    if let item = try? await source.info(itemPath) { dragged.append(item) }
                }
                TransferCenter.shared.enqueue(items: dragged, from: source, to: self.backend, directory: target)
            }
            return true
        }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let local = FilesCoordinator.shared.local
            var dragged: [FileItem] = []
            for url in urls {
                if let item = try? await local.info(url.path) { dragged.append(item) }
            }
            TransferCenter.shared.enqueue(items: dragged, from: local, to: self.backend, directory: target)
        }
        return true
    }
}

// MARK: - Inline rename

extension FilePaneViewController: NSTextFieldDelegate {
    @objc func renameFieldDone(_ sender: NSTextField) {
        guard let row = renamingRow, row < displayItems.count else { return }
        let item = displayItems[row]
        renamingRow = nil
        let newName = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else {
            listView.reloadData()
            return
        }
        Task {
            do {
                let parent = FilePath.parent(item.path) ?? path
                try await backend.move(item.path, to: FilePath.join(parent, newName))
                load()
            } catch { showError(error) }
        }
    }
}

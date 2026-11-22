import AppKit

/// NSOutlineView identifies items by object identity, so the sidebar uses a
/// class rather than a value type. Instances are cached per kind so expansion
/// state survives reloads.
final class SidebarNode: NSObject {
    enum Kind {
        case section(String)
        case location(FileLocation)
        case macRoot
        case device(String)

        var key: String {
            switch self {
            case .section(let name): return "section:" + name
            case .location(let location): return "location:" + location.id
            case .macRoot: return "mac"
            case .device(let serial): return "device:" + serial
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

/// A source-list row: symbol, title and an optional second line.
final class SidebarCell: NSTableCellView {
    let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        textField = title

        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        imageView = icon
        addSubview(icon)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }
}

@MainActor
final class SidebarController: NSViewController {
    weak var browser: FilesBrowserController?

    private let outline = NSOutlineView()
    private var devices: [Device] = []
    private var locations: [String: [FileLocation]] = [:]
    private var macFavorites: [FileLocation] = []
    private var nodeCache: [String: SidebarNode] = [:]
    private var didAutoExpand = false

    override func loadView() {
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.autoresizingMask = [.width]
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(choose(_:))

        // Without a column an NSOutlineView renders nothing at all.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 120
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = outline
        outline.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
        view = scroll

        macFavorites = favoriteLocations()
        devices = FilesCoordinator.shared.devices

        NotificationCenter.default.addObserver(
            forName: .bezelDevicesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDevices() }
        }

        outline.reloadData()
        refreshDevices()
    }

    // MARK: - Data

    private func favoriteLocations() -> [FileLocation] {
        let home = NSHomeDirectory()
        let local = FilesCoordinator.shared.local.id
        var result: [FileLocation] = [
            FileLocation(backendID: local, path: home, title: "Home", symbol: "house"),
            FileLocation(backendID: local, path: home + "/Desktop", title: "Desktop", symbol: "menubar.dock.rectangle"),
            FileLocation(backendID: local, path: home + "/Documents", title: "Documents", symbol: "doc"),
            FileLocation(backendID: local, path: home + "/Downloads", title: "Downloads", symbol: "arrow.down.circle"),
            FileLocation(backendID: local, path: home + "/Movies", title: "Movies", symbol: "film"),
            FileLocation(backendID: local, path: home + "/Pictures", title: "Pictures", symbol: "photo")
        ]
        result.append(FileLocation(
            backendID: local,
            path: Settings.defaultFolder.path,
            title: "Bezel Recordings",
            symbol: "video"
        ))
        return result
    }

    private func node(_ kind: SidebarNode.Kind) -> SidebarNode {
        if let cached = nodeCache[kind.key] { return cached }
        let created = SidebarNode(kind)
        nodeCache[kind.key] = created
        return created
    }

    func refreshDevices() {
        let coordinator = FilesCoordinator.shared
        let updated = coordinator.devices
        let serials = Set(updated.map(\.serial))

        // Drop cached nodes for phones that went away.
        nodeCache = nodeCache.filter { key, node in
            if case .device(let serial) = node.kind { return serials.contains(serial) }
            if case .location(let location) = node.kind {
                return !location.backendID.contains(":")
                    || serials.contains(String(location.backendID.split(separator: ":").first ?? ""))
            }
            return true
        }

        devices = updated
        outline.reloadData()

        for device in updated where locations[device.serial] == nil {
            Task { [weak self] in
                let found = await coordinator.androidLocations(serial: device.serial)
                guard let self else { return }
                await MainActor.run {
                    self.didAutoExpand = false    // allow expansion once data arrives
                    self.locations[device.serial] = found
                    self.outline.reloadItem(
                        self.node(.device(device.serial)),
                        reloadChildren: true
                    )
                    self.autoExpandPreferredDevice()
                }
            }
        }

        // Run once synchronously; if locations already populated it’s a no-op,
        // otherwise it will run again (idempotent) after the Tasks finish.
        autoExpandPreferredDevice()
    }

    /// Show the internal storage of the phone the mirror is using without
    /// making the user hunt for the disclosure triangle. Selecting is left to
    /// the user so the last-used folder is not hijacked on launch.
    private func autoExpandPreferredDevice() {
        guard !didAutoExpand,
              let device = FilesCoordinator.shared.preferredDevice(),
              locations[device.serial]?.isEmpty == false else { return }
        didAutoExpand = true
        outline.expandItem(node(.device(device.serial)))
    }

    /// Test seam: the outline itself stays private.
    var debugRowCount: Int { outline.numberOfRows }

    func debugTitle(atRow row: Int) -> String? {
        guard row >= 0, row < outline.numberOfRows,
              let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        return title(for: node)
    }

    private func nodes(for parent: Any?) -> [SidebarNode] {
        guard let parent else {
            var roots: [SidebarNode] = [node(.section("FAVORITES"))]
            roots += macFavorites.map { node(.location($0)) }
            roots.append(node(.section("LOCATIONS")))
            roots.append(node(.macRoot))
            roots += devices.map { node(.device($0.serial)) }
            return roots
        }
        if let node = parent as? SidebarNode, case .device(let serial) = node.kind {
            return (locations[serial] ?? []).map { self.node(.location($0)) }
        }
        return []
    }

    private func title(for node: SidebarNode) -> String {
        switch node.kind {
        case .section(let name): return name
        case .location(let location): return location.title
        case .macRoot: return "This Mac"
        case .device(let serial):
            return FilesCoordinator.shared.device(serial: serial)?.displayName ?? serial
        }
    }

    private func subtitle(for node: SidebarNode) -> String? {
        switch node.kind {
        case .device(let serial):
            guard let device = FilesCoordinator.shared.device(serial: serial) else { return nil }
            return device.isReady ? "Android \(device.android)" : device.state
        case .location(let location):
            return location.subtitle
        default:
            return nil
        }
    }

    private func symbol(for node: SidebarNode) -> String? {
        switch node.kind {
        case .location(let location): return location.symbol
        case .macRoot: return "laptopcomputer"
        case .device: return "iphone.gen3"
        case .section: return nil
        }
    }

    // MARK: - Selection

    @objc private func choose(_ sender: Any) {
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        select(node)
    }

    private func select(_ node: SidebarNode) {
        switch node.kind {
        case .location(let location):
            guard let backend = FilesCoordinator.shared.backend(for: location.backendID) else { return }
            browser?.activate(pane: browser?.primaryPane)
            browser?.primaryPane.navigate(to: backend, path: location.path)
        case .macRoot:
            let local = FilesCoordinator.shared.local
            browser?.primaryPane.navigate(to: local, path: local.defaultPath)
        case .device(let serial):
            guard let found = locations[serial]?.first,
                  let backend = FilesCoordinator.shared.backend(for: found.backendID) else { return }
            browser?.primaryPane.navigate(to: backend, path: found.path)
        case .section:
            break
        }
    }
}

extension SidebarController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        nodes(for: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        nodes(for: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .device = node.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .section = node.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .section = node.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return 24 }
        switch node.kind {
        case .section: return 22
        case .device: return 34
        default: return 24
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }

        if case .section(let name) = node.kind {
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("SidebarSection")
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        let cell = (outlineView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("SidebarItem"),
            owner: self
        ) as? SidebarCell) ?? SidebarCell()
        cell.identifier = NSUserInterfaceItemIdentifier("SidebarItem")
        cell.textField?.stringValue = title(for: node)
        cell.textField?.textColor = .labelColor
        cell.subtitle.stringValue = subtitle(for: node) ?? ""
        cell.subtitle.isHidden = subtitle(for: node) == nil
        cell.imageView?.image = symbol(for: node).flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        cell.imageView?.contentTintColor = .controlAccentColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline = notification.object as? NSOutlineView,
              let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        select(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let object = notification.userInfo?["NSObject"] as? SidebarNode,
              case .device(let serial) = object.kind else { return }
        guard let entries = locations[serial], entries.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let found = await FilesCoordinator.shared.androidLocations(serial: serial)
            await MainActor.run {
                self.locations[serial] = found
                self.outline.reloadItem(object, reloadChildren: true)
            }
        }
    }
}

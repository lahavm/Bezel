import AppKit

private enum SidebarNode: Hashable {
    case section(String)
    case location(FileLocation)
    case macRoot
    case device(String)
}

final class SidebarCell: NSTableCellView {
    let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)
        NSLayoutConstraint.activate([
            subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            subtitle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        textField?.translatesAutoresizingMaskIntoConstraints = false
        if let textField {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                textField.topAnchor.constraint(equalTo: topAnchor, constant: 4)
            ])
        }
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

    override func loadView() {
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(choose(_:))
        outline.allowsEmptySelection = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = outline
        outline.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
        view = scroll

        macFavorites = favoriteLocations()
        devices = FilesCoordinator.shared.devices
        outline.reloadData()
        refreshDevices()

        NotificationCenter.default.addObserver(
            forName: .bezelDevicesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDevices() }
        }
    }

    private func favoriteLocations() -> [FileLocation] {
        let home = NSHomeDirectory()
        let coordinator = FilesCoordinator.shared
        var result: [FileLocation] = [
            FileLocation(backendID: coordinator.local.id, path: home, title: "Home", symbol: "house"),
            FileLocation(backendID: coordinator.local.id, path: home + "/Desktop", title: "Desktop", symbol: "rectangle.on.rectangle"),
            FileLocation(backendID: coordinator.local.id, path: home + "/Documents", title: "Documents", symbol: "doc"),
            FileLocation(backendID: coordinator.local.id, path: home + "/Downloads", title: "Downloads", symbol: "arrow.down.circle"),
            FileLocation(backendID: coordinator.local.id, path: home + "/Movies", title: "Movies", symbol: "film"),
            FileLocation(backendID: coordinator.local.id, path: home + "/Pictures", title: "Pictures", symbol: "photo")
        ]
        let recordings = Settings.defaultFolder.path
        result.append(FileLocation(
            backendID: coordinator.local.id,
            path: recordings,
            title: "Bezel Recordings",
            symbol: "video"
        ))
        return result
    }

    func refreshDevices() {
        let coordinator = FilesCoordinator.shared
        let newDevices = coordinator.devices
        for device in newDevices where locations[device.serial] == nil {
            Task { [weak self] in
                let found = await coordinator.androidLocations(serial: device.serial)
                guard let self else { return }
                await MainActor.run {
                    self.locations[device.serial] = found
                    self.outline.reloadData()
                }
            }
        }
        devices = newDevices
        outline.reloadData()
    }

    @objc private func choose(_ sender: Any) {
        let item = outline.item(atRow: outline.selectedRow)
        guard let node = item as? SidebarNode else { return }
        select(node)
    }

    private func select(_ node: SidebarNode) {
        switch node {
        case .location(let location):
            guard let backend = FilesCoordinator.shared.backend(for: location.backendID) else { return }
            browser?.activate(pane: browser?.primaryPane)
            browser?.primaryPane.navigate(to: backend, path: location.path)
        case .macRoot:
            let local = FilesCoordinator.shared.local
            browser?.primaryPane.navigate(to: local, path: local.defaultPath)
        case .device(let serial):
            guard let found = locations[serial]?.first else { return }
            if let backend = FilesCoordinator.shared.backend(for: found.backendID) {
                browser?.primaryPane.navigate(to: backend, path: found.path)
            }
        case .section:
            break
        }
    }

    private func nodes(for parent: Any?) -> [SidebarNode] {
        guard let parent else {
            var roots: [SidebarNode] = [.section("FAVORITES")]
            roots += macFavorites.map { .location($0) }
            roots.append(.section("LOCATIONS"))
            roots.append(.macRoot)
            roots += devices.map { .device($0.serial) }
            return roots
        }
        if case .device(let serial) = parent as? SidebarNode {
            return (locations[serial] ?? []).map { .location($0) }
        }
        return []
    }

    private func title(for node: SidebarNode) -> String {
        switch node {
        case .section(let name): return name
        case .location(let location): return location.title
        case .macRoot: return "This Mac"
        case .device(let serial):
            return FilesCoordinator.shared.device(serial: serial)?.displayName ?? serial
        }
    }

    private func subtitle(for node: SidebarNode) -> String? {
        switch node {
        case .device(let serial):
            let device = FilesCoordinator.shared.device(serial: serial)
            return device?.isReady == true ? "Android \(device?.android ?? "")" : device?.state
        case .location(let location):
            return location.subtitle
        default:
            return nil
        }
    }

    private func image(for node: SidebarNode) -> NSImage? {
        let symbol: String
        switch node {
        case .location(let location): symbol = location.symbol
        case .macRoot: symbol = "laptopcomputer"
        case .device: symbol = "iphone.gen3"
        case .section: return nil
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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
        if case .device = node { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if case .section = node {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title(for: node))
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let cell = SidebarCell()
        cell.identifier = NSUserInterfaceItemIdentifier("SidebarItem")
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image(for: node)
        imageView.contentTintColor = .controlAccentColor
        cell.imageView = imageView
        cell.addSubview(imageView)
        cell.textField?.stringValue = title(for: node)
        cell.subtitle.stringValue = subtitle(for: node) ?? ""
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -4),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16)
        ])
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return 24 }
        if case .device = node { return 38 }
        if case .section = node { return 26 }
        return 26
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .section = node { return false }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline = notification.object as? NSOutlineView,
              let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        select(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let object = notification.userInfo?["NSObject"] as? SidebarNode,
              case .device(let serial) = object else { return }
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

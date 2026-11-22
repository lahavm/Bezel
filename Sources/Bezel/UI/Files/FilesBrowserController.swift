import AppKit

/// The three-column browser: sidebar, one or two panes, optional info pane.
@MainActor
final class FilesBrowserController: NSViewController {
    let primaryPane: FilePaneViewController
    private(set) var secondaryPane: FilePaneViewController?
    private(set) var activePane: FilePaneViewController
    let sidebar = SidebarController()
    let preview = FilePreviewPane()
    weak var windowController: FilesTabController?

    private let outerSplit = NSSplitView()
    private let paneSplit = NSSplitView()
    private let center = NSView()

    init(backend: any FileBackend, path: String) {
        primaryPane = FilePaneViewController(backend: backend, path: path)
        activePane = primaryPane
        super.init(nibName: nil, bundle: nil)
        primaryPane.browser = self
        sidebar.browser = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override func loadView() {
        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thin
        paneSplit.addArrangedSubview(primaryPane.view)
        paneSplit.delegate = self

        center.addSubview(paneSplit)
        paneSplit.translatesAutoresizingMaskIntoConstraints = false
        center.autoresizingMask = [.width, .height]
        NSLayoutConstraint.activate([
            paneSplit.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            paneSplit.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            paneSplit.topAnchor.constraint(equalTo: center.topAnchor),
            paneSplit.bottomAnchor.constraint(equalTo: center.bottomAnchor)
        ])

        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.addArrangedSubview(sidebar.view)
        outerSplit.addArrangedSubview(center)
        if FilesCoordinator.shared.settings.filesShowPreview {
            outerSplit.addArrangedSubview(preview.view)
        }
        outerSplit.delegate = self
        view = outerSplit
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Always re-apply layout when the view appears (important when reused as a tab)
        outerSplit.setPosition(220, ofDividerAt: 0)
        if FilesCoordinator.shared.settings.filesShowPreview, outerSplit.subviews.count >= 3 {
            outerSplit.setPosition(max(520, outerSplit.frame.width - 280), ofDividerAt: 1)
        }
        // Ensure the center view resizes with the window
        center.autoresizingMask = [.width, .height]
    }

    func activate(pane: FilePaneViewController?) {
        guard let pane else { return }
        activePane = pane
        selectionChanged()
    }

    func selectionChanged() {
        guard FilesCoordinator.shared.settings.filesShowPreview else {
            preview.clear()
            return
        }
        preview.show(activePane.selectSingle(), backend: activePane.backend)
    }

    func setSplit(_ on: Bool) {
        FilesCoordinator.shared.settings.filesSplit = on
        FilesCoordinator.shared.settings.save()
        if on, secondaryPane == nil {
            let local = FilesCoordinator.shared.local
            let path = FilesCoordinator.shared.settings.filesLastPaths[local.id] ?? local.defaultPath
            let pane = FilePaneViewController(backend: local, path: path)
            pane.browser = self
            secondaryPane = pane
            paneSplit.addArrangedSubview(pane.view)
            paneSplit.setPosition(paneSplit.frame.width / 2, ofDividerAt: 0)
        } else if !on, let secondaryPane {
            secondaryPane.view.removeFromSuperview()
            self.secondaryPane = nil
            activePane = primaryPane
            selectionChanged()
        }
    }

    func setPreview(_ on: Bool) {
        FilesCoordinator.shared.settings.filesShowPreview = on
        FilesCoordinator.shared.settings.save()
        if on, !outerSplit.subviews.contains(preview.view) {
            outerSplit.addArrangedSubview(preview.view)
            outerSplit.setPosition(max(520, outerSplit.frame.width - 280), ofDividerAt: 1)
        } else if !on, outerSplit.subviews.contains(preview.view) {
            preview.view.removeFromSuperview()
        }
        selectionChanged()
    }

    func refreshAll() {
        primaryPane.load()
        secondaryPane?.load()
    }
}

extension FilesBrowserController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === outerSplit {
            return dividerIndex == 0 ? 190 : 480
        }
        return 320
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        splitView === outerSplit && subview === preview.view
    }
}

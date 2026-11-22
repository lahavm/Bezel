import AppKit

/// The optional right-hand info panel.
@MainActor
final class FilePreviewPane: NSViewController {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let modifiedLabel = NSTextField(labelWithString: "")
    private let permissionsLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewText = NSTextView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        for label in [kindLabel, sizeLabel, modifiedLabel, permissionsLabel, pathLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        pathLabel.lineBreakMode = .byCharWrapping

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.font = .systemFont(ofSize: 11)
        previewText.textColor = .secondaryLabelColor
        previewText.drawsBackground = false

        let stack = NSStackView(views: [
            imageView, nameLabel, kindLabel, sizeLabel, modifiedLabel, permissionsLabel, pathLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = previewText
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 220),
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),

            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        view = container
        clear()
    }

    func clear() {
        nameLabel.stringValue = "No Selection"
        kindLabel.stringValue = ""
        sizeLabel.stringValue = ""
        modifiedLabel.stringValue = ""
        permissionsLabel.stringValue = ""
        pathLabel.stringValue = ""
        imageView.image = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil)
        previewText.string = ""
    }

    func show(_ item: FileItem?, backend: any FileBackend) {
        guard let item else { clear(); return }
        nameLabel.stringValue = item.name
        kindLabel.stringValue = item.kind
        sizeLabel.stringValue = item.isDirectory ? "Folder" : item.displaySize
        modifiedLabel.stringValue = "Modified \(item.displayModified)"
        permissionsLabel.stringValue = item.permissions.isEmpty ? "" : "Permissions \(item.permissions)"
        pathLabel.stringValue = item.path
        imageView.image = NSWorkspace.shared.icon(for: item.type)
        previewText.string = ""

        Task { @MainActor in
            if let image = await ThumbnailCache.shared.image(for: item, backend: backend, maxPixel: 600) {
                imageView.image = image
            } else if item.type.conforms(to: .plainText) || item.type.conforms(to: .sourceCode) {
                if let data = try? await backend.read(item.path, maxBytes: 4096) {
                    let text = String(decoding: data, as: UTF8.self)
                    previewText.string = text.isEmpty ? "" : text + (data.count >= 4096 ? "\n…" : "")
                }
            }
        }
    }
}

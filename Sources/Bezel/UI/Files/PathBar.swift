import AppKit

/// Finder-style clickable path bar.
final class PathBar: NSView {
    var onSelect: ((Int) -> Void)?

    private let stack = NSStackView()
    private var titles: [String] = []
    private var symbol = "folder"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    func set(components: [String], symbol: String) {
        self.titles = components
        self.symbol = symbol
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        func button(_ title: String, index: Int, image: NSImage?) -> NSButton {
            let button = NSButton(title: title, target: self, action: #selector(select(_:)))
            button.tag = index
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.image = image
            button.imagePosition = image == nil ? .noImage : .imageLeading
            button.imageScaling = .scaleProportionallyDown
            return button
        }

        let rootImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        stack.addArrangedSubview(button(titles.first ?? "Files", index: 0, image: rootImage))
        for (offset, title) in titles.dropFirst().enumerated() {
            let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            let separator = NSImageView(image: chevron!)
            separator.contentTintColor = .tertiaryLabelColor
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.widthAnchor.constraint(equalToConstant: 12).isActive = true
            stack.addArrangedSubview(separator)
            stack.addArrangedSubview(button(title, index: offset + 1, image: nil))
        }
    }

    @objc private func select(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
}

import AVFoundation
import SwiftUI

struct PreviewView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let state: AppState

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.state = state
        view.attach(layer)
        return view
    }

    func updateNSView(_ nsView: PreviewLayerView, context: Context) {
        nsView.state = state
        nsView.attach(layer)
    }
}

/// Shows the phone picture and turns clicks, drags, the scroll wheel and keys
/// into phone input. The picture is aspect-fit, so points are mapped from the
/// view into video pixels before they are sent.
final class PreviewLayerView: NSView {
    weak var state: AppState?

    /// SwiftUI builds this representable more than once and every copy shares the
    /// one video layer. A layer can only live in one place, so it is hosted as a
    /// sublayer and only by the copy that is in a window: a discarded copy would
    /// otherwise take it from the on-screen view, which then freezes on the last
    /// frame it composited. Re-hosted on every update as well, so a steal heals.
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    private var touching = false
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        host()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        host()
    }

    override func layout() {
        super.layout()
        host()
    }

    private func host() {
        guard let displayLayer, window != nil, let layer else { return }
        if displayLayer.superlayer !== layer {
            layer.addSublayer(displayLayer)
            Log.write("preview: layer hosted \(Int(bounds.width))x\(Int(bounds.height))")
        }
        displayLayer.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = phonePoint(event, clamp: false) else { return }
        touching = true
        state?.sendTouch(.down, at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let point = phonePoint(event, clamp: true) else { return }
        state?.sendTouch(.move, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching, let point = phonePoint(event, clamp: true) else { return }
        touching = false
        state?.sendTouch(.up, at: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        state?.sendKey(.back)
    }

    override func keyDown(with event: NSEvent) {
        guard let state, let stroke = KeyMap.stroke(for: event) else {
            super.keyDown(with: event)
            return
        }
        state.sendKey(stroke)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = phonePoint(event, clamp: true) else { return }
        // Trackpads report fine-grained points; wheels report whole lines.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.05 : 1
        scrollX += event.scrollingDeltaX * scale
        scrollY += event.scrollingDeltaY * scale
        let dx = scrollX.rounded(.towardZero)
        let dy = scrollY.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return }
        scrollX -= dx
        scrollY -= dy
        state?.sendScroll(
            dx: Int16(clamping: Int(-dx)),
            dy: Int16(clamping: Int(-dy)),
            at: point
        )
    }

    /// View point → video pixel, or nil when the click is in the black bars.
    private func phonePoint(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        guard let state, state.canControlPhone else { return nil }
        let video = state.frameSize
        let area = bounds.size
        guard area.width > 0, area.height > 0 else { return nil }

        let aspect = video.width / video.height
        let container = area.width / area.height
        let picture: CGRect
        if aspect > container {
            let height = area.width / aspect
            picture = CGRect(x: 0, y: (area.height - height) / 2, width: area.width, height: height)
        } else {
            let width = area.height * aspect
            picture = CGRect(x: (area.width - width) / 2, y: 0, width: width, height: area.height)
        }

        var point = convert(event.locationInWindow, from: nil)
        guard picture.width > 0 else { return nil }
        if clamp {
            point.x = min(max(point.x, picture.minX), picture.maxX)
            point.y = min(max(point.y, picture.minY), picture.maxY)
        } else if !picture.contains(point) {
            return nil
        }
        let u = (point.x - picture.minX) / picture.width
        let v = 1 - (point.y - picture.minY) / picture.height // AppKit is y-up.
        return CGPoint(x: u * video.width, y: v * video.height)
    }
}


/// Hosts the Mac camera layer with a real AppKit layer mask. A SwiftUI
/// `clipShape` does not reliably clip a layer-backed `NSView`, so the heart and
/// circle outlines are applied to the layer itself.
/// Hosts the Mac camera layer with a real AppKit layer mask. A SwiftUI
/// `clipShape` does not reliably clip a layer-backed `NSView`, so the heart and
/// circle outlines are applied to the layer itself.
struct CameraLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let shape: Settings.WebcamShape
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> CameraContainerView {
        let view = CameraContainerView()
        view.attach(layer, shape: shape, cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: CameraContainerView, context: Context) {
        nsView.attach(layer, shape: shape, cornerRadius: cornerRadius)
    }

    final class CameraContainerView: NSView {
        private let maskLayer = CAShapeLayer()
        private weak var displayLayer: AVSampleBufferDisplayLayer?
        private var shape: Settings.WebcamShape = .rounded
        private var cornerRadius: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func attach(_ displayLayer: AVSampleBufferDisplayLayer, shape: Settings.WebcamShape, cornerRadius: CGFloat) {
            self.shape = shape
            self.cornerRadius = cornerRadius
            if self.displayLayer !== displayLayer, let layer {
                self.displayLayer?.removeFromSuperlayer()
                self.displayLayer = displayLayer
                displayLayer.frame = bounds
                layer.addSublayer(displayLayer)
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            displayLayer?.frame = bounds
            updateMask()
        }

        private func updateMask() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            switch shape {
            case .rectangle:
                layer?.mask = nil
            case .rounded:
                layer?.mask = maskLayer
                maskLayer.frame = bounds
                maskLayer.path = CGPath(
                    roundedRect: bounds,
                    cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius,
                    transform: nil
                )
            case .circle:
                layer?.mask = maskLayer
                maskLayer.frame = bounds
                maskLayer.path = CGPath(ellipseIn: bounds, transform: nil)
            case .heart:
                layer?.mask = maskLayer
                maskLayer.frame = bounds
                maskLayer.path = HeartPath.cgPath(in: bounds, flipped: true)
            }
        }
    }
}

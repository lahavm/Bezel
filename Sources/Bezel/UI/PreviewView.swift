import AVFoundation
import SwiftUI

struct PreviewView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


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

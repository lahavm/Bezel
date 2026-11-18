import SwiftUI

/// A customizable heart shape used by the camera overlay and preview.
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(HeartPath.cgPath(in: rect))
    }
}

/// The draggable Mac camera inset. Its size and shape match the exported
/// picture-in-picture frame.
struct CameraOverlay: View {
    @Environment(AppState.self) private var state
    let available: CGSize
    @State private var translation: CGSize = .zero
    @State private var isDragging = false
    @State private var isHovering = false

    private var width: CGFloat { available.width * CGFloat(state.settings.webcamScale) }
    private var height: CGFloat {
        state.settings.webcamShape.isSquare ? width : width * 9 / 16
    }
    private var base: CGPoint {
        clamped(CGPoint(
            x: available.width * state.settings.webcamX,
            y: available.height * state.settings.webcamY
        ))
    }
    private var shape: AnyShape {
        switch state.settings.webcamShape {
        case .rounded:
            return AnyShape(RoundedRectangle(cornerRadius: width * 0.06))
        case .rectangle:
            return AnyShape(Rectangle())
        case .circle:
            return AnyShape(Circle())
        case .heart:
            return AnyShape(HeartShape())
        }
    }

    var body: some View {
        let currentPos = clamped(CGPoint(
            x: base.x + translation.width,
            y: base.y + translation.height
        ))

        CameraLayerView(
            layer: state.webcamPreview.displayLayer,
            shape: state.settings.webcamShape,
            cornerRadius: width * 0.06
        )
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    isDragging ? Color.accentColor : (isHovering ? Color.white.opacity(0.45) : Color.white.opacity(0.2)),
                    lineWidth: isDragging ? 2 : 1
                )
            }
            .shadow(color: .black.opacity(isDragging ? 0.5 : 0.35), radius: isDragging ? 16 : 10, y: isDragging ? 6 : 3)
            .contentShape(shape)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            NSCursor.closedHand.push()
                        }
                        translation = value.translation
                    }
                    .onEnded { value in
                        if isDragging {
                            isDragging = false
                            NSCursor.pop()
                        }
                        let final = clamped(CGPoint(
                            x: base.x + value.translation.width,
                            y: base.y + value.translation.height
                        ))
                        state.settings.webcamX = final.x / max(1, available.width)
                        state.settings.webcamY = final.y / max(1, available.height)
                        translation = .zero
                    }
            )
            .onTapGesture(count: 2) {
                // Double-click resets camera position to default bottom-right
                state.settings.webcamX = 0.82
                state.settings.webcamY = 0.75
            }
            .position(currentPos)
            .help("Drag to move camera · Double-click to reset position")
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let margin = available.width * 0.02
        let minX = width / 2 + margin
        let maxX = max(minX, available.width - width / 2 - margin)
        let minY = height / 2 + margin
        let maxY = max(minY, available.height - height / 2 - margin)
        let x = min(maxX, max(minX, point.x))
        let y = min(maxY, max(minY, point.y))
        return CGPoint(x: x, y: y)
    }
}

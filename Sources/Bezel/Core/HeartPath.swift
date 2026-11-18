import CoreGraphics

/// The heart outline used by both the SwiftUI overlay and the video export.
enum HeartPath {
    /// When flipped is true (CoreGraphics with (0,0) at bottom-left), the heart
    /// is upright.
    static func cgPath(in rect: CGRect, flipped: Bool = false) -> CGPath {
        let side = min(rect.width, rect.height)
        let xOffset = rect.minX + (rect.width - side) / 2
        let yOffset = rect.minY + (rect.height - side) / 2
        let r = CGRect(x: xOffset, y: yOffset, width: side, height: side)

        let path = CGMutablePath()
        func pt(_ normX: CGFloat, _ normY: CGFloat) -> CGPoint {
            let actualY = flipped ? (1.0 - normY) : normY
            return CGPoint(x: r.minX + r.width * normX, y: r.minY + r.height * actualY)
        }

        path.move(to: pt(0.5, 0.25))
        path.addCurve(
            to: pt(0.04, 0.28),
            control1: pt(0.28, -0.06),
            control2: pt(0.04, 0.06)
        )
        path.addCurve(
            to: pt(0.5, 0.96),
            control1: pt(0.04, 0.56),
            control2: pt(0.34, 0.78)
        )
        path.addCurve(
            to: pt(0.96, 0.28),
            control1: pt(0.66, 0.78),
            control2: pt(0.96, 0.56)
        )
        path.addCurve(
            to: pt(0.5, 0.25),
            control1: pt(0.96, 0.06),
            control2: pt(0.72, -0.06)
        )
        path.closeSubpath()
        return path
    }
}

import SwiftUI

/// The small Bezel mark used in the toolbar and the empty preview state. It is
/// the same idea as the app icon: a phone, its bezel, and the camera inset.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.17, green: 0.19, blue: 0.24),
                        Color(red: 0.05, green: 0.06, blue: 0.09)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))

            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.5), .white.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                ), lineWidth: max(0.5, size * 0.035))

            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .inset(by: size * 0.2)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.32, blue: 0.52),
                        Color(red: 0.18, green: 0.68, blue: 0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Circle()
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.35, green: 0.78, blue: 0.88),
                        Color(red: 0.03, green: 0.09, blue: 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.6), lineWidth: max(0.4, size * 0.018))
                }
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(x: size * 0.23, y: size * 0.23)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Bezel")
    }
}

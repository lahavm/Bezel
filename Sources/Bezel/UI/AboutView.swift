import SwiftUI

/// About panel: version, what it does, and where to find the source.
struct AboutView: View {
    let version: String
    let githubURL: URL

    var body: some View {
        VStack(spacing: 0) {
            BrandMark(size: 64)
                .padding(.top, 30)
                .padding(.bottom, 14)

            Text("Bezel")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Mirror and record your Android phone over USB on macOS 26+. Personal use only — free, no telemetry, nothing installed on the phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 20)

            HStack(spacing: 18) {
                Link("Source on GitHub", destination: githubURL)
                    .font(.subheadline)
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 420)
    }
}

/// Hosts the About view in its own small window, opened from the Help menu.
enum AboutPanel {
    static let githubURL = URL(string: "https://github.com/lahavm/Bezel")!
    private static var window: NSWindow?

    static func show(version: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(rootView: AboutView(version: version, githubURL: githubURL))
        let created = NSWindow(contentViewController: hosting)
        created.title = "About Bezel"
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}


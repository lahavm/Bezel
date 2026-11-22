import AppKit
import SwiftUI

struct HelpView: View {
    let version: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        BrandMark(size: 48)
                        Text("Bezel Help")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("Version \(version)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    FeatureSection(title: "Mirror") {
                        HelpRow(icon: "iphone.gen3", title: "Phone mirroring", detail: "See and control your Android phone on the Mac over USB. Nothing is installed on the phone and no account is needed.")
                        HelpRow(icon: "record.circle", title: "Record & screenshot", detail: "⌘R starts or stops a recording, ⌘S takes a screenshot. The camera overlay adds a webcam picture-in-picture.")
                    }

                    FeatureSection(title: "Files") {
                        HelpRow(icon: "folder", title: "Two panes, one window", detail: "⌘B toggles between Mirror and Files. The sidebar lists Mac folders and connected phones. ⇧⌘B opens Files in its own window.")
                        HelpRow(icon: "arrow.right", title: "Finder → phone", detail: "Drag files from Finder onto the Bezel window to copy them into the phone's Download folder. iOS/Android devices must be connected.")
                        HelpRow(icon: "arrow.left", title: "Phone → Finder", detail: "Drag files from the Files list onto a Finder window or the Desktop to download them. Large folders are copied in the background.")
                        HelpRow(icon: "magnifyingglass", title: "Search & sort", detail: "Use the search field to filter files, and the toolbar controls to switch views, sort, or create folders.")
                    }

                    FeatureSection(title: "Getting started") {
                        HelpRow(icon: "wrench", title: "Connect the phone", detail: "Enable Developer options and USB debugging on the phone, connect with a data cable, approve the USB debugging prompt, then pick the device in the top bar and press ⌘↩.")
                        HelpRow(icon: "hand.raised", title: "Privacy", detail: "Bezel is for personal use. No telemetry, no account, no data leaves your Mac except the files you transfer.")
                    }
                }
                .padding(20)
            }

            HStack {
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }
}

private struct FeatureSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
    }
}

private struct HelpRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Presents the help window from the Help menu. SwiftUI Commands can't host a
/// sheet, so this mirrors AboutPanel's standalone-window approach.
enum HelpPanel {
    private static var window: NSWindow?

    static func show(version: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(rootView: HelpView(version: version))
        let created = NSWindow(contentViewController: hosting)
        created.title = "Bezel Help"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.isReleasedWhenClosed = false
        created.setContentSize(NSSize(width: 520, height: 560))
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

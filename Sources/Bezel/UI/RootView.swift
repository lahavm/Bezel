import AppKit
import SwiftUI

enum BezelTab {
    case mirror
    case files
}

/// One window, two compact tabs. Native window tabbing is deliberately not
/// used: macOS 26 draws very large tabs with it and merging a second window
/// makes the window jump.
struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var tab: BezelTab = .mirror
    @State private var filesMounted = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ZStack {
                ContentView()
                    .opacity(tab == .mirror ? 1 : 0)
                    .allowsHitTesting(tab == .mirror)
                if filesMounted {
                    FilesHost()
                        .opacity(tab == .files ? 1 : 0)
                        .allowsHitTesting(tab == .files)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bezelShowFiles)) { _ in
            select(.files)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFilesTab)) { _ in
            if tab == .mirror { select(.files) } else { select(.mirror) }
        }
        .onChange(of: tab) { _, _ in
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .task {
            FilesCoordinator.shared.attach(state)
            if ProcessInfo.processInfo.environment["BEZEL_OPEN_FILES"] == "1" {
                FilesCoordinator.shared.showFiles()
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.mirror, title: "Mirror", symbol: "iphone.and.arrow.forward")
                .help("Mirror the connected phone")
            tabButton(.files, title: "Files", symbol: "folder")
                .help("Browse this Mac and the phone (⌘B)")
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
    }

    private func tabButton(_ value: BezelTab, title: String, symbol: String) -> some View {
        Button {
            select(value)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(tab == value ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tab == value ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ value: BezelTab) {
        if value == .files { filesMounted = true }
        tab = value
        FilesCoordinator.shared.filesTabIsVisible = value == .files
    }
}

private struct FilesHost: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> FilesTabController {
        FilesCoordinator.shared.filesTab()
    }

    func updateNSViewController(_ controller: FilesTabController, context: Context) {}
}

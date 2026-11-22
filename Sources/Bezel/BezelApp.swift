import AppKit
import SwiftUI

/// Registers the Finder "Send to Android" service.
final class FinderServiceProvider: NSObject {
    static let shared = FinderServiceProvider()

    @objc func sendToAndroid(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Select one or more files in Finder first." as NSString
            return
        }
        Task { @MainActor in
            FilesCoordinator.shared.sendToAndroid(urls)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = FinderServiceProvider.shared
        NSUpdateDynamicServices()

        // Replace the default "Bezel Help" item (which shows the system's
        // "Help is not available" message) with our own help window.
        let menu = NSMenu()
        let item = NSMenuItem(title: "Bezel Help", action: #selector(showHelp(_:)), keyEquivalent: "?")
        item.target = self
        menu.addItem(item)
        NSApp.helpMenu = menu
    }

    @objc private func showHelp(_ sender: Any) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        HelpPanel.show(version: version)
    }
}

@main
struct BezelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Bezel") {
            RootView()
                .environment(state)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Files") {
                    NotificationCenter.default.post(name: .toggleFilesTab, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Files in New Window") { openFiles(asTab: false) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("Capture") {
                Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                    state.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!state.isRunning)

                Button("Screenshot") { state.takeScreenshot() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!state.isRunning)

                Divider()

                Button("Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])

                Button("Show Recordings in Finder") {
                    let saved = [state.lastRecording, state.lastWebcamRecording, state.lastScreenshot].compactMap { $0 }
                    guard !saved.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting(saved)
                }
                .disabled(state.lastRecording == nil && state.lastWebcamRecording == nil && state.lastScreenshot == nil)
            }
            CommandMenu("Device") {
                Button(state.isRunning ? "Disconnect" : "Connect") {
                    if state.isRunning {
                        state.disconnect()
                    } else {
                        Task { await state.connect() }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.isRunning && !state.canConnect)
            }
            CommandMenu("Files") {
                Button("New Folder") { FilesCoordinator.shared.activeFiles()?.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Rename") { FilesCoordinator.shared.activeFiles()?.rename() }
                Button("Move to Trash / Delete") { FilesCoordinator.shared.activeFiles()?.delete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Quick Look") { FilesCoordinator.shared.activeFiles()?.quickLookSelection() }
                Divider()
                Button("Split Panes") { FilesCoordinator.shared.activeFiles()?.toggleSplitView() }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Show Preview") { FilesCoordinator.shared.activeFiles()?.togglePreviewPane() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Hidden Files") { FilesCoordinator.shared.activeFiles()?.toggleHiddenFiles() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Refresh") { FilesCoordinator.shared.activeFiles()?.refreshPanes() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Divider()
                Button("About Bezel") {
                    AboutPanel.show(version: state.version)
                }
                Link("Bezel on GitHub", destination: AboutPanel.githubURL)
            }
        }
    }

    private func openFiles(asTab: Bool) {
        FilesCoordinator.shared.attach(state)
        FilesCoordinator.shared.showFiles(asTab: asTab)
    }
}

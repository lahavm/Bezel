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
    }
}

@main
struct BezelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Bezel") {
            ContentView()
                .environment(state)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    FilesCoordinator.shared.attach(state)
                    if ProcessInfo.processInfo.environment["BEZEL_OPEN_FILES"] == "1" {
                        FilesCoordinator.shared.open(asTab: false)
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Files") { openFiles(asTab: true) }
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
                Button("New Folder") { FilesCoordinator.shared.activeWindow()?.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Rename") { FilesCoordinator.shared.activeWindow()?.rename() }
                Button("Move to Trash / Delete") { FilesCoordinator.shared.activeWindow()?.delete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Quick Look") { FilesCoordinator.shared.activeWindow()?.quickLookSelection() }
                Divider()
                Button("Split Panes") { FilesCoordinator.shared.activeWindow()?.toggleSplitView() }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Show Preview") { FilesCoordinator.shared.activeWindow()?.togglePreviewPane() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Hidden Files") { FilesCoordinator.shared.activeWindow()?.toggleHiddenFiles() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Refresh") { FilesCoordinator.shared.activeWindow()?.refreshPanes() }
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
        FilesCoordinator.shared.open(asTab: asTab)
    }
}

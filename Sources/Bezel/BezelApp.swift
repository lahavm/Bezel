import AppKit
import SwiftUI

@main
struct BezelApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Bezel") {
            ContentView()
                .environment(state)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        }
    }
}

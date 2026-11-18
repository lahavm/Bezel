import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var showError = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            topBar(state: state)
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                inspector(state: state)
                    .frame(width: 264)
                    .background(.regularMaterial)
            }
        }
        .task { state.startMonitoring() }
        .alert(
            "Connection problem",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private func topBar(state: AppState) -> some View {
        @Bindable var state = state

        return HStack(spacing: 12) {
            Menu {
                if state.devices.isEmpty {
                    Text("No devices")
                }
                ForEach(state.devices) { device in
                    Button {
                        state.selectedSerial = device.serial
                    } label: {
                        Text(device.displayName)
                    }
                }
            } label: {
                Label(state.selectedDevice?.displayName ?? "Select device", systemImage: "iphone.gen3")
                    .frame(minWidth: 160, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh devices")

            Spacer()

            Circle()
                .fill(state.isRunning ? .green : (state.canConnect ? .orange : .secondary))
                .frame(width: 7, height: 7)

            Text(state.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if state.isRunning {
                Button {
                    if state.isRecording {
                        Task { await state.stopRecording() }
                    } else {
                        do { try state.startRecording() } catch {
                            state.errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label(state.isRecording ? "Stop recording" : "Record",
                          systemImage: state.isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.bordered)
                .tint(state.isRecording ? .red : nil)
            }

            Button(state.isRunning ? "Stop" : "Connect") {
                if state.isRunning {
                    state.disconnect()
                } else {
                    Task { await state.connect() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isRunning ? false : !state.canConnect)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var preview: some View {
        ZStack {
            Color.black
            PreviewView(layer: state.renderer.layer)

            if !state.isRunning {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(state.canConnect ? "Ready to mirror" : "Connect a device over USB")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                    if state.canConnect && !state.isConnecting {
                        Text("⌘↩")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }

            if state.isConnecting {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if state.isRunning {
                HStack(spacing: 10) {
                    if state.frameSize != .zero {
                        Text("\(Int(state.frameSize.width))×\(Int(state.frameSize.height))")
                    }
                    Text("\(state.renderer.framesPerSecond) fps")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(14)
            }
        }
    }

    private func clock(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func inspector(state: AppState) -> some View {
        @Bindable var state = state

        return Form {
            Section("Source") {
                Picker("Input", selection: $state.settings.source) {
                    ForEach(Settings.Source.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if state.settings.source == .camera {
                    Picker("Lens", selection: $state.settings.cameraFacing) {
                        Text("Back").tag("back")
                        Text("Front").tag("front")
                        Text("External").tag("external")
                    }
                }
            }
            .disabled(state.isRunning)

            Section("Quality") {
                Picker("Resolution", selection: $state.settings.resolution) {
                    ForEach(Settings.Resolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                Picker("Frame rate", selection: $state.settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Codec", selection: $state.settings.codec) {
                    Text("H.264").tag("h264")
                    Text("HEVC").tag("h265")
                }
            }
            .disabled(state.isRunning)

            Section("Recording") {
                if state.isRecording, let start = state.recordStart {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Label(clock(from: start, to: context.date), systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout.monospacedDigit())
                    }
                }

                if let url = state.lastRecording, !state.isRecording {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(url.lastPathComponent, systemImage: "film")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }

                Text("Saved to Movies/Bezel. Video passes through without re-encoding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

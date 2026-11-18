import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var isFullScreen = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            if !isFullScreen {
                topBar(state: state)
                Divider()
            }
            HStack(spacing: 0) {
                preview
                if !isFullScreen {
                    Divider()
                    inspector(state: state)
                        .frame(width: 286)
                        .background(.regularMaterial)
                }
            }
        }
        .background(shortcutButtons)
        .task { state.startMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onChange(of: state.settings.source) { state.restartSession() }
        .onChange(of: state.settings.cameraId) { state.restartSession() }
        .onChange(of: state.settings.resolution) { state.restartSession() }
        .onChange(of: state.settings.fps) { state.restartSession() }
        .onChange(of: state.settings.codec) { state.restartSession() }
        .alert(
            "Problem",
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

    /// Invisible buttons so the shortcuts work even when their toolbar
    /// counterparts are hidden in full screen.
    private var shortcutButtons: some View {
        VStack {
            Button("Record") { state.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Screenshot") { state.takeScreenshot() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Full screen") { toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
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
                    .frame(minWidth: 150, alignment: .leading)
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
                    state.takeScreenshot()
                } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(.borderless)
                .help("Screenshot (⌘S)")
            }

            if state.isRunning || state.settings.target.recordsWebcam {
                Button {
                    state.toggleRecording()
                } label: {
                    Label(state.isRecording ? "Stop" : "Record",
                          systemImage: state.isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(.bordered)
                .tint(state.isRecording ? .red : nil)
                .help("Record (⌘R)")
            }

            Button {
                toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Full screen (⌃⌘F)")

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

            if !state.isRunning && !state.isComposing {
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

            if state.isComposing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finishing recording…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(20)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
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
        .overlay(alignment: .topTrailing) {
            if state.isRecording, let start = state.recordStart, isFullScreen {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(clock(from: start, to: context.date))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                }
                .padding(14)
            }
        }
    }

    private var recordingURLs: [URL] {
        [state.lastRecording, state.lastWebcamRecording, state.lastScreenshot].compactMap { $0 }
    }

    private func clock(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = state.settings.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            state.settings.recordingsFolder = url.path
        }
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
                .disabled(state.isRecording)

                if state.settings.source == .camera {
                    if state.cameras.isEmpty {
                        Picker("Lens", selection: $state.settings.cameraFacing) {
                            Text("Back").tag("back")
                            Text("Front").tag("front")
                            Text("External").tag("external")
                        }
                    } else {
                        Picker("Lens", selection: $state.settings.cameraId) {
                            Text("Auto").tag(Int?.none)
                            ForEach(state.cameras) { camera in
                                Text(camera.label).tag(Int?.some(camera.id))
                            }
                        }
                    }
                }
            }

            Section("Record") {
                Picker("Source", selection: $state.settings.target) {
                    ForEach(Settings.Target.allCases) { target in
                        Text(target.rawValue).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                if state.settings.target.recordsPhone {
                    Picker("Phone audio", selection: $state.settings.audio) {
                        ForEach(Settings.Audio.allCases) { audio in
                            Text(audio.rawValue).tag(audio)
                        }
                    }
                    .disabled(state.isRunning)
                }

                if state.settings.target.recordsWebcam {
                    Picker("Mac camera", selection: $state.settings.webcamResolution) {
                        Text("1080p").tag(1080)
                        Text("4K").tag(2160)
                    }

                    if state.settings.target == .both {
                        Toggle("Separate files", isOn: $state.settings.separateFiles)
                            .help("Off: one video with the Mac camera in the corner.")
                    }
                }

                Toggle("Record Mac microphone", isOn: $state.settings.macMic)
            }
            .disabled(state.isRecording)

            Section("Quality") {
                Picker("Resolution", selection: $state.settings.resolution) {
                    ForEach(Settings.Resolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                Picker("Frame rate", selection: $state.settings.fps) {
                    Text("Native").tag(0)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Codec", selection: $state.settings.codec) {
                    Text("H.264").tag("h264")
                    Text("HEVC").tag("h265")
                }
            }
            .disabled(state.isRecording)

            Section("Save to") {
                HStack {
                    Text(state.settings.outputDirectory.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(state.settings.outputDirectory.path)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(.borderless)
                }
                if !state.settings.recordingsFolder.isEmpty {
                    Button("Use Movies/Bezel") {
                        state.settings.recordingsFolder = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .disabled(state.isRecording)

            Section("Recording") {
                if state.isRecording, let start = state.recordStart {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Label(clock(from: start, to: context.date), systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout.monospacedDigit())
                    }
                }

                Button {
                    state.takeScreenshot()
                } label: {
                    Label("Screenshot", systemImage: "camera")
                }
                .buttonStyle(.borderless)
                .disabled(!state.isRunning)

                ForEach(recordingURLs, id: \.self) { url in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(url.lastPathComponent, systemImage: url.pathExtension == "png" ? "photo" : "film")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }

                Text("⌘R record · ⌘S screenshot · ⌃⌘F full screen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

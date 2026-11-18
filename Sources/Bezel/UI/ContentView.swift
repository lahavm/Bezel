import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var isFullScreen = false
    @State private var showInspector = true
    @State private var autoFoldedForRecording = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            if !isFullScreen {
                topBar(state: state)
                Divider()
            }
            HStack(spacing: 0) {
                preview
                if !isFullScreen, showInspector {
                    Divider()
                    inspector(state: state)
                        .frame(width: 286)
                        .background(.regularMaterial)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.24), value: showInspector)
        }
        .task { state.startMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onChange(of: state.settings.target) { state.syncWebcamPreview() }
        .onChange(of: state.settings.webcamBlur) { state.syncWebcamPreview() }
        .onChange(of: state.settings.webcamBlurAmount) { state.syncWebcamPreview() }
        .onChange(of: state.settings.macMic) { state.syncMicMonitor() }
        .onChange(of: state.settings.micId) { state.syncMicMonitor() }
        .onChange(of: state.settings.micVolume) { state.syncAudioVolumes() }
        .onChange(of: state.settings.phoneVolume) { state.syncAudioVolumes() }
        .onChange(of: state.settings.hearPhoneAudio) { state.syncAudioVolumes() }
        .onChange(of: state.settings.source) { state.restartSession() }
        .onChange(of: state.settings.cameraId) { state.restartSession() }
        .onChange(of: state.settings.resolution) { state.restartSession() }
        .onChange(of: state.settings.fps) { state.restartSession() }
        .onChange(of: state.settings.codec) { state.restartSession() }
        .onChange(of: state.isRecording) {
            if state.isRecording {
                guard showInspector else { return }
                autoFoldedForRecording = true
                showInspector = false
            } else if autoFoldedForRecording {
                autoFoldedForRecording = false
                showInspector = true
            }
        }
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
        .sheet(isPresented: $state.showWelcome) {
            WelcomeView()
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func toggleInspector() {
        autoFoldedForRecording = false
        showInspector.toggle()
    }

    private func topBar(state: AppState) -> some View {
        @Bindable var state = state

        return HStack(spacing: 12) {
            HStack(spacing: 7) {
                BrandMark(size: 20)
                Text("Bezel")
                    .font(.system(size: 14, weight: .semibold))
            }
            .accessibilityElement(children: .combine)

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

            Button(state.isRunning ? "Stop" : "Connect") {
                if state.isRunning {
                    state.disconnect()
                } else {
                    Task { await state.connect() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isRunning ? false : !state.canConnect)

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

            Button {
                toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Full screen (⌃⌘F)")

            if state.isRunning {
                HStack(spacing: 6) {
                    Button {
                        state.toggleRecording()
                    } label: {
                        Label(state.isRecording ? "Stop" : "Record",
                              systemImage: state.isRecording ? "stop.fill" : "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(state.isRecording ? .red : nil)
                    .help("Record (⌘R)")

                    if state.isRecording, let start = state.recordStart {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                Text(clock(from: start, to: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            Button {
                toggleInspector()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide inspector (⌘\\)" : "Show inspector (⌘\\)")
            .keyboardShortcut("\\", modifiers: .command)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The Mac camera in the bottom-right corner, matching what the PiP export
    /// writes.
    private var cameraPreview: some View {
        GeometryReader { geo in
            let rect = videoRect(in: geo.size)
            CameraOverlay(available: rect.size)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    /// The phone picture is aspect-fit inside the preview, so the camera inset
    /// has to use the picture's rectangle rather than the whole pane.
    private func videoRect(in size: CGSize) -> CGRect {
        guard state.frameSize.width > 0, state.frameSize.height > 0,
              size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let aspect = state.frameSize.width / state.frameSize.height
        let container = size.width / size.height
        if aspect > container {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private var preview: some View {
        ZStack {
            Color.black
            PreviewView(layer: state.renderer.layer, state: state)

            if state.settings.target.recordsWebcam {
                cameraPreview
            }

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

                    Divider()
                        .frame(height: 11)
                        .opacity(0.4)

                    audioHUD
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(14)
            }
        }
        .overlay(alignment: .top) {
            if state.isRecording, let start = state.recordStart, isFullScreen {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    HStack(spacing: 7) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("REC")
                            .font(.caption2.weight(.bold))
                            .kerning(0.6)
                        Text(clock(from: start, to: context.date))
                            .font(.caption.monospacedDigit())
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
                .padding(.top, 16)
                .allowsHitTesting(false)
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

                Toggle("Mouse & keyboard control", isOn: $state.settings.control)
                    .disabled(state.isRecording || state.settings.source == .camera)
                    .onChange(of: state.settings.control) { state.restartSession() }
                    .help("Click, drag and scroll on the mirror, type on the Mac keyboard, right-click or Esc to go back. Turning it off or on reconnects.")
            }

            Section("Record") {
                Picker("Output", selection: $state.settings.target) {
                    ForEach(Settings.Target.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Phone audio", selection: $state.settings.audio) {
                    ForEach(Settings.Audio.allCases) { audio in
                        Text(audio.rawValue).tag(audio)
                    }
                }
                .disabled(state.isRunning)

                if state.settings.target.recordsWebcam {
                    Toggle("Separate files", isOn: $state.settings.separateFiles)
                        .help("Off: one file with the phone, Mac camera, and microphone. On: a phone file and a Mac camera file with the microphone.")
                }

                Toggle("Record Mac microphone", isOn: $state.settings.macMic)

                if state.settings.macMic {
                    Picker("Microphone", selection: $state.settings.micId) {
                        Text("Auto").tag(String?.none)
                        ForEach(state.microphones) { mic in
                            Text(mic.name).tag(String?.some(mic.id))
                        }
                    }

                    if state.isMicDenied {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Microphone permission denied.")
                                .font(.caption)
                            Spacer()
                            Button("Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
            .disabled(state.isRecording)

            Section("Levels") {
                if state.settings.audio != .none {
                    VolumeControl(
                        title: "Phone",
                        icon: "speaker.wave.2.fill",
                        level: state.phoneLevel,
                        volume: $state.settings.phoneVolume
                    )
                    Toggle("Hear phone on Mac", isOn: $state.settings.hearPhoneAudio)
                        .font(.caption)
                        .help("Play phone audio live through your Mac speakers or headphones.")
                }
                if state.settings.macMic {
                    VolumeControl(
                        title: "Mac microphone",
                        icon: "mic.fill",
                        level: state.micLevel,
                        volume: $state.settings.micVolume
                    )
                }
                if state.settings.audio == .none && !state.settings.macMic {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.slash.fill")
                                .foregroundStyle(.orange)
                            Text("No audio is being recorded.")
                                .font(.callout)
                                .fontWeight(.medium)
                        }
                        Text("Your recording will have no sound. Turn on Phone audio or Mac microphone to capture audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Record Phone Audio") {
                                state.settings.audio = .device
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(state.isRunning)

                            Button("Record Mac Mic") {
                                state.settings.macMic = true
                                state.syncMicMonitor()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }
            }

            if state.settings.target.recordsWebcam {
                Section("Camera overlay") {
                    Picker("Shape", selection: $state.settings.webcamShape) {
                        ForEach(Settings.WebcamShape.allCases) { shape in
                            Text(shape.rawValue).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(Int((state.settings.webcamScale * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $state.settings.webcamScale, in: 0.15...0.50)
                            .controlSize(.small)
                    }

                    Toggle("Background blur", isOn: $state.settings.webcamBlur)

                    if state.settings.webcamBlur {
                        HStack(spacing: 8) {
                            Text("Blur amount")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.settings.webcamBlurAmount, in: 0.1...1.0)
                                .controlSize(.small)
                            Text("\(Int(state.settings.webcamBlurAmount * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                        .padding(.leading, 4)
                    }

                    HStack {
                        Text(state.settings.separateFiles
                             ? "Separate files records the Mac camera full-frame; shape, size and blur shape the combined file."
                             : "Drag the camera in the preview to place it. The export uses the same spot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Reset position") {
                            state.settings.webcamX = 0.82
                            state.settings.webcamY = 0.75
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .disabled(state.isRecording)
            }

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

                Text("⌘R record · ⌘S screenshot · ⌃⌘F full screen · ⌘\\ inspector")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Inspector")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.7)
                    Spacer()
                    Button {
                        toggleInspector()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Hide inspector (⌘\\)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var audioHUD: some View {
        if state.settings.audio == .none && !state.settings.macMic {
            HStack(spacing: 4) {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(.orange)
                Text("No audio")
                    .foregroundStyle(.orange)
            }
            .help("No audio is enabled. The recording will have no sound.")
        } else {
            HStack(spacing: 8) {
                if state.settings.audio != .none {
                    HStack(spacing: 4) {
                        Image(systemName: state.settings.phoneVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(state.settings.phoneVolume <= 0.001 ? .red : .white.opacity(0.85))
                        MiniLevelMeter(level: min(1, state.phoneLevel * Float(state.settings.phoneVolume)))
                    }
                    .help(state.settings.phoneVolume <= 0.001 ? "Phone audio: Muted" : "Phone audio level")
                }
                if state.settings.macMic {
                    HStack(spacing: 4) {
                        Image(systemName: state.settings.micVolume <= 0.001 ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(state.settings.micVolume <= 0.001 ? .red : .white.opacity(0.85))
                        MiniLevelMeter(level: min(1, state.micLevel * Float(state.settings.micVolume)))
                    }
                    .help(state.settings.micVolume <= 0.001 ? "Mac microphone: Muted" : "Mac microphone level")
                }
            }
        }
    }
}

private struct MiniLevelMeter: View {
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.25))
            Capsule()
                .fill(LinearGradient(
                    colors: [.green, .yellow, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: 28 * CGFloat(max(0, min(1, level))))
                .animation(.linear(duration: 0.08), value: level)
        }
        .frame(width: 28, height: 4)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
    }
}

private struct VolumeControl: View {
    let title: String
    let icon: String
    let level: Float
    @Binding var volume: Double

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if volume <= 0.001 {
                    Text("MUTED")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else {
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    if volume > 0.001 {
                        volume = 0
                    } else {
                        volume = 1.0
                    }
                } label: {
                    Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(volume <= 0.001 ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(volume <= 0.001 ? "Unmute" : "Mute")
            }
            LevelMeter(level: min(1, level * Float(volume)))
            HStack(spacing: 8) {
                Slider(value: $volume, in: 0...2)
                    .controlSize(.small)
                if abs(volume - 1.0) > 0.01 && volume > 0.001 {
                    Button("100%") {
                        volume = 1.0
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Reset to 100%")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

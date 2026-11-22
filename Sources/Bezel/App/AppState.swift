import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    let adb = ADB()
    let renderer = PreviewRenderer()
    let recorder = Recorder()
    let webcamRecorder = WebcamRecorder()
    let webcamPreview = WebcamPreview()
    let snapshotter = Snapshotter()
    let phoneMeter = PhoneAudioMeter()
    let micMeter = MicLevelMonitor()
    let phonePlayer = PhoneAudioPlayer()

    var devices: [Device] = []
    var selectedSerial: String?
    var settings = Settings.load() {
        didSet { settings.save() }
    }
    var status = "Plug in a device"
    var errorMessage: String?
    var isRunning = false
    var isConnecting = false
    var frameSize = CGSize.zero
    var isRecording = false
    var recordStart: Date?
    var lastRecording: URL?
    var lastWebcamRecording: URL?
    var lastScreenshot: URL?
    var isComposing = false
    var showWelcome = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.2"
    }
    var phoneLevel: Float = 0
    var micLevel: Float = 0
    var cameras: [CameraInfo] = []
    var microphones: [MicInfo] = []

    private var session: ScrcpySession?
    /// The phone's original stay-awake setting, and which phone it came from so
    /// it can be put back even after the device list has moved on.
    private var stayAwake: (serial: String, before: String)?
    private var monitor: Task<Void, Never>?
    private var didAutoConnect = false
    private var lastDeviceLog = "unset"
    private var probedSerial = ""
    private var recordingHasPhoneAudio = false
    private var recordingHasMicInPhone = false
    private var recordingUsesWebcamMic = false
    private var recordingPhoneVolume: Float = 1

    init() {
        switch ProcessInfo.processInfo.environment["BEZEL_RESOLUTION"] {
        case "4k": settings.resolution = .uhd
        case "1440p": settings.resolution = .qhd
        case "1080p": settings.resolution = .fhd
        case "720p": settings.resolution = .hd
        case "native": settings.resolution = .native
        default: break
        }
        if ProcessInfo.processInfo.environment["BEZEL_MACMIC"] == "1" {
            settings.macMic = true
        }
        if let value = Double(ProcessInfo.processInfo.environment["BEZEL_PHONEVOL"] ?? "") {
            settings.phoneVolume = value
        }
        if let value = Double(ProcessInfo.processInfo.environment["BEZEL_MICVOL"] ?? "") {
            settings.micVolume = value
        }
        if ProcessInfo.processInfo.environment["BEZEL_BLUR"] == "1" {
            settings.webcamBlur = true
        }
        switch ProcessInfo.processInfo.environment["BEZEL_SHAPE"] {
        case "circle": settings.webcamShape = .circle
        case "heart": settings.webcamShape = .heart
        case "rectangle": settings.webcamShape = .rectangle
        default: break
        }
        if let value = Double(ProcessInfo.processInfo.environment["BEZEL_SCALE"] ?? "") {
            settings.webcamScale = value
        }
        switch ProcessInfo.processInfo.environment["BEZEL_SIZE"] {
        case "small": settings.webcamSize = .small
        case "large": settings.webcamSize = .large
        case "medium": settings.webcamSize = .medium
        default: break
        }
        if let value = Double(ProcessInfo.processInfo.environment["BEZEL_CAMX"] ?? "") {
            settings.webcamX = value
        }
        if let value = Double(ProcessInfo.processInfo.environment["BEZEL_CAMY"] ?? "") {
            settings.webcamY = value
        }
        if ProcessInfo.processInfo.environment["BEZEL_SOURCE"] == "camera" {
            settings.source = .camera
        }
        switch ProcessInfo.processInfo.environment["BEZEL_TARGET"] {
        case "both": settings.target = .both
        default: break
        }
        if ProcessInfo.processInfo.environment["BEZEL_SEPARATE"] == "1" {
            settings.separateFiles = true
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        phoneMeter.onLevel = { [weak self] level in
            Task { @MainActor in self?.phoneLevel = level }
        }
        phoneMeter.onFormat = { [weak self] sampleRate, channels in
            self?.phonePlayer.configure(sampleRate: sampleRate, channels: channels)
        }
        phoneMeter.onPCM = { [weak self] samples, frameCount, channels in
            self?.phonePlayer.play(samples: samples, frameCount: frameCount, channels: channels)
        }
        micMeter.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        let hasSeen = settings.hasSeenWelcome
        showWelcome = !hasSeen
        Log.write("app: state created")
    }

    static var serverJar: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("scrcpy-server.jar")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor")
            .appendingPathComponent("scrcpy-server-v\(ScrcpySession.serverVersion)")
    }

    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    var canConnect: Bool {
        guard let device = selectedDevice else { return false }
        return device.isReady && !isConnecting
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        Log.write("monitor: start")
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var isMicDenied: Bool {
        settings.macMic && AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    /// Shows the Mac camera overlay whenever a Mac camera is part of the recording.
    func syncWebcamPreview() {
        if settings.target.recordsWebcam {
            webcamPreview.setBlur(settings.webcamBlur, amount: settings.webcamBlurAmount)
            Task { [weak self] in
                _ = await self?.webcamPreview.start()
            }
        } else {
            webcamPreview.setFrameSink(nil)
            webcamPreview.stop()
        }
    }

    func syncMicMonitor() {
        if settings.macMic {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor in
                        if granted {
                            self?.syncMicMonitor()
                        }
                    }
                }
                return
            }
            micMeter.start(id: settings.micId, gain: settings.micVolume)
        } else {
            micMeter.stop()
            micLevel = 0
        }
    }

    func syncAudioVolumes() {
        recorder.setMicVolume(settings.micVolume)
        webcamRecorder.setMicVolume(settings.micVolume)
        recordingPhoneVolume = Float(settings.phoneVolume)
        phonePlayer.setEnabled(settings.hearPhoneAudio && settings.audio != .none)
        phonePlayer.setVolume(settings.phoneVolume)
        syncMicMonitor()
    }

    func refresh() async {
        syncWebcamPreview()
        let mics = Microphone.devices()
        if mics != microphones {
            microphones = mics
            if let id = settings.micId, !mics.contains(where: { $0.id == id }) {
                settings.micId = nil
            }
            Log.write("microphones: \(mics.map(\.name).joined(separator: ", "))")
        }
        syncMicMonitor()
        guard !isRunning, !isConnecting else { return }
        do {
            let found = try await adb.devices()
            devices = found
            let summary = found.map { "\($0.serial):\($0.state):\($0.model):\($0.android)" }.joined(separator: ",")
            if summary != lastDeviceLog {
                lastDeviceLog = summary
                Log.write("devices: [\(summary)]")
            }
            if selectedSerial == nil || !found.contains(where: { $0.serial == selectedSerial }) {
                selectedSerial = found.first(where: \.isReady)?.serial ?? found.first?.serial
            }
            if let device = selectedDevice {
                if device.isReady, settings.source == .camera, probedSerial != device.serial {
                    probedSerial = device.serial
                    Task { [weak self] in
                        guard let self else { return }
                        let found = await self.adb.cameras(device.serial, jar: Self.serverJar, version: ScrcpySession.serverVersion)
                        self.cameras = found
                        if let current = self.settings.cameraId, !found.contains(where: { $0.id == current }) {
                            self.settings.cameraId = nil
                        }
                        Log.write("cameras: \(found.map { "\($0.id):\($0.facing):\($0.size)" }.joined(separator: ","))")
                    }
                }
                switch device.state {
                case "device":
                    status = device.sdk > 0 ? "Android \(device.android) · ready" : "Ready"
                case "unauthorized":
                    status = "Approve USB debugging on the device"
                case "offline":
                    status = "Device offline — reconnect the cable"
                default:
                    status = device.state
                }
            } else {
                status = "Plug in a device"
            }
            errorMessage = nil

            if ProcessInfo.processInfo.environment["BEZEL_AUTOCONNECT"] == "1",
               !didAutoConnect, canConnect, !isRunning {
                didAutoConnect = true
                Log.write("auto-connect: \(selectedSerial ?? "none")")
                Task { await connect() }
            }
        } catch {
            devices = []
            selectedSerial = nil
            status = "adb unavailable"
            errorMessage = error.localizedDescription
            Log.write("refresh failed: \(error.localizedDescription)")
        }
    }

    func connect() async {
        guard let device = selectedDevice, !isConnecting, !isRunning else { return }
        errorMessage = nil
        Log.write("connect: \(device.serial) source=\(settings.source.rawValue) \(settings.resolution.label) \(settings.fps)fps \(settings.codec)")
        renderer.flush()
        frameSize = .zero
        isConnecting = true
        status = "Connecting…"

        // A phone that hits its screen timeout stops producing frames, which
        // looks like a frozen preview. Mirroring needs it awake (scrcpy's
        // --stay-awake). 7 = AC|USB|wireless, because a USB-C hub can report AC.
        if stayAwake == nil,
           let before = try? await adb.shellCommand(
               device.serial, "settings get global stay_on_while_plugged_in"
           ) {
            stayAwake = (device.serial, before)
        }
        _ = try? await adb.shellCommand(device.serial, "settings put global stay_on_while_plugged_in 7")
        _ = try? await adb.shellCommand(device.serial, "input keyevent 224")

        let session = ScrcpySession(device: device, adb: adb)
        session.onSample = { [weak self, weak session] sample, isKeyframe in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.renderer.enqueue(sample)
                if self.isRecording {
                    self.recorder.append(sample, isKeyframe: isKeyframe)
                }
            }
        }
        session.onAudioConfig = { [weak self, weak session] asc in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.phoneMeter.configure(asc: asc)
                guard self.isRecording else { return }
                self.recorder.configureAudio(asc: asc)
            }
        }
        session.onAudioFrame = { [weak self, weak session] frame, pts in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.phoneMeter.process(frame)
                guard self.isRecording else { return }
                self.recorder.appendAudio(frame: frame, ptsMicros: pts)
            }
        }
        session.onSize = { [weak self, weak session] width, height in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.frameSize = CGSize(width: width, height: height)
            }
        }
        session.onEnd = { [weak self, weak session] message in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.finish(message: message)
            }
        }
        self.session = session

        do {
            try await session.start(settings: settings)
            isRunning = true
            isConnecting = false
            status = "Live"

            if let seconds = Double(ProcessInfo.processInfo.environment["BEZEL_RECORD_SECONDS"] ?? ""), seconds > 0 {
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.startRecording()
                    try? await Task.sleep(for: .seconds(seconds))
                    await self.stopRecording()
                }
            }

        } catch {
            session.stop()
            self.session = nil
            isConnecting = false
            isRunning = false
            status = "Stopped"
            errorMessage = error.localizedDescription
            Log.write("connect failed: \(error.localizedDescription)")
        }
    }

    /// Stops the device process and the private adb daemon. Called on quit so
    /// nothing of ours keeps running in the background.
    func shutdown() {
        Log.write("app: shutdown")
        webcamPreview.setFrameSink(nil)
        webcamPreview.stop()
        phonePlayer.stop()
        if let session {
            adb.cleanupSync(
                serial: session.deviceSerial,
                remoteJar: ScrcpySession.remoteJar,
                reverse: session.reverseTarget
            )
        }
        session?.stop()
        session = nil
        guard adb.startedServer else { return }
        let process = Process()
        process.executableURL = adb.adbURL
        process.arguments = ["kill-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_USER_HOME"] = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bezel/android").path

        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                do { try await startRecording() } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func takeScreenshot() {
        guard let buffer = renderer.displayedPixelBuffer() else {
            errorMessage = "There is no frame on screen yet."
            return
        }
        let directory = settings.outputDirectory
        Task.detached { [snapshotter] in
            do {
                let url = try snapshotter.save(buffer, into: directory)
                await MainActor.run { self.lastScreenshot = url }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.errorMessage = message
                    Log.write("screenshot: failed \(message)")
                }
            }
        }
    }

    /// Reconnects with the current settings, so source, lens and quality can
    /// change without pressing Stop and Connect.
    func restartSession() {
        guard isRunning, !isConnecting, !isRecording else { return }
        Task {
            session?.stop()
            session = nil
            isRunning = false
            renderer.flush()
            frameSize = .zero
            // Give the phone a moment to release the camera/encoder.
            try? await Task.sleep(for: .milliseconds(600))
            await connect()
        }
    }

    // MARK: - Phone input

    /// The preview can drive the phone only while a screen session is live.
    var canControlPhone: Bool {
        isRunning && settings.control && settings.source == .screen && frameSize.width > 0
    }

    func sendTouch(_ action: ControlMessages.Action, at point: CGPoint) {
        guard canControlPhone, let session else { return }
        session.send(ControlMessages.touch(
            action,
            x: Int32(point.x.rounded()),
            y: Int32(point.y.rounded()),
            width: UInt16(min(frameSize.width, 65_535)),
            height: UInt16(min(frameSize.height, 65_535))
        ))
    }

    func sendScroll(dx: Int16, dy: Int16, at point: CGPoint) {
        guard canControlPhone, let session, dx != 0 || dy != 0 else { return }
        session.send(ControlMessages.scroll(
            x: Int32(point.x.rounded()),
            y: Int32(point.y.rounded()),
            width: UInt16(min(frameSize.width, 65_535)),
            height: UInt16(min(frameSize.height, 65_535)),
            dx: dx,
            dy: dy
        ))
    }

    func sendKey(_ stroke: KeyMap.Stroke) {
        guard canControlPhone, let session else { return }
        switch stroke {
        case .back:
            session.send(ControlMessages.back)
        case .key(let code, let meta):
            session.send(ControlMessages.key(code: code, down: true, meta: meta))
            session.send(ControlMessages.key(code: code, down: false, meta: meta))
        }
    }

    func startRecording() async throws {
        guard !isRecording else { return }
        guard isRunning, let session, session.isRunning else {
            finish(message: nil)
            throw RecorderError.writer("The phone is not connected. Connect it and try again.")
        }

        let directory = settings.outputDirectory
        var startedURLs: [URL] = []

        recordingHasPhoneAudio = settings.audio != .none
        recordingUsesWebcamMic = settings.macMic && settings.target.recordsWebcam && settings.separateFiles
        recordingHasMicInPhone = settings.macMic && !recordingUsesWebcamMic
        recordingPhoneVolume = Float(settings.phoneVolume)

        if settings.macMic {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.writer("Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone.")
            }
        }

        // The preview owns the only Mac camera session. Start it before the
        // writer so the webcam file receives frames from the very beginning.
        if settings.target.recordsWebcam {
            let running = await webcamPreview.start()
            guard running else {
                throw WebcamError.configuration("The Mac camera could not be started. Check camera access in System Settings › Privacy & Security › Camera.")
            }
            webcamPreview.setBlur(settings.webcamBlur, amount: settings.webcamBlurAmount)
        }

        // The audio format has to be registered before the first video frame
        // starts the writer, so give the device a moment to send it.
        if settings.audio != .none, session.audioConfig == nil {
            for _ in 0..<30 where session.audioConfig == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let phoneURL = try recorder.start(fps: settings.fps, directory: directory)
        if let asc = session.audioConfig {
            recorder.configureAudio(asc: asc)
        }
        if recordingHasMicInPhone {
            try recorder.startMicrophone(id: settings.micId, volume: settings.micVolume)
        }
        lastRecording = phoneURL
        startedURLs.append(phoneURL)
        Log.write("recording: phone \(phoneURL.path)")

        if settings.target.recordsWebcam {
            do {
                let url = try await webcamRecorder.start(
                    fps: max(30, settings.fps),
                    microphone: recordingUsesWebcamMic ? settings.micId : nil,
                    volume: settings.micVolume,
                    directory: directory
                )
                webcamPreview.setFrameSink { [weak webcamRecorder] sample in
                    webcamRecorder?.appendVideo(sample)
                }
                lastWebcamRecording = url
                startedURLs.append(url)
            } catch {
                webcamPreview.setFrameSink(nil)
                if !startedURLs.isEmpty {
                    _ = try? await recorder.finish()
                }
                throw error
            }
        }

        // Attach the phone, mic and webcam writers first; starting the file
        // before the last input is added is not allowed.
        if let seed = session.recordingSeed() {
            recorder.seed(seed.sample, at: seed.pts, continuous: seed.continuous)
        }

        recordStart = Date()
        isRecording = true
        Log.write("recording: start (\(startedURLs.count) file(s))")
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordStart = nil
        webcamPreview.setFrameSink(nil)
        var saved: [URL] = []
        var phoneURL: URL?
        var webcamURL: URL?

        do {
            let url = try await recorder.finish()
            lastRecording = url
            phoneURL = url
            saved.append(url)
            Log.write("recording: saved \(url.path)")
        } catch {
            Log.write("recording: phone failed \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        if settings.target.recordsWebcam {
            do {
                let url = try await webcamRecorder.finish()
                lastWebcamRecording = url
                webcamURL = url
                saved.append(url)
                Log.write("recording: saved webcam \(url.path)")
            } catch {
                Log.write("recording: webcam failed \(error.localizedDescription)")
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
            webcamRecorder.stopSession()
        }

        let needsAudioPass = recordingHasMicInPhone
            || (recordingHasPhoneAudio && recordingPhoneVolume != 1)
        if needsAudioPass, let phoneURL {
            isComposing = true
            status = "Mixing audio…"
            let scratch = phoneURL.deletingLastPathComponent()
                .appendingPathComponent(".bezel-mix-\(UUID().uuidString).mp4")
            do {
                let mixed = try await AudioMixer.mix(
                    phoneURL,
                    output: scratch,
                    phoneVolume: recordingPhoneVolume,
                    hasPhoneAudio: recordingHasPhoneAudio,
                    hasMicAudio: recordingHasMicInPhone
                )
                if mixed != phoneURL {
                    try? FileManager.default.removeItem(at: phoneURL)
                    try? FileManager.default.moveItem(at: scratch, to: phoneURL)
                    lastRecording = phoneURL
                }
                Log.write("mix: final \(phoneURL.path)")
            } catch {
                Log.write("mix: failed \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            isComposing = false
        }

        if !settings.separateFiles, settings.target == .both, let phoneURL, let webcamURL {
            isComposing = true
            status = "Composing picture in picture…"
            let base = phoneURL.deletingPathExtension().lastPathComponent
            let output = phoneURL.deletingLastPathComponent().appendingPathComponent("\(base) PiP.mp4")
            do {
                let options = PiPOptions(
                    shape: settings.webcamShape,
                    scale: settings.webcamScale,
                    x: settings.webcamX,
                    y: settings.webcamY,
                    blur: settings.webcamBlur,
                    blurAmount: settings.webcamBlurAmount
                )
                let composite = try await PiPExporter.compose(
                    phone: phoneURL,
                    webcam: webcamURL,
                    output: output,
                    options: options
                )
                if composite != phoneURL { try? FileManager.default.removeItem(at: phoneURL) }
                try? FileManager.default.removeItem(at: webcamURL)
                lastRecording = composite
                lastWebcamRecording = nil
                saved = [composite]
                Log.write("pip: final \(composite.path)")
            } catch {
                Log.write("pip: failed \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            isComposing = false
        }

        if isRunning { status = "Live" }
    }

    func disconnect() {
        restoreStayAwake()
        if isRecording {
            Task { await stopRecording() }
        }
        phonePlayer.stop()
        session?.stop()
        session = nil
        isRunning = false
        isConnecting = false
        renderer.flush()
        frameSize = .zero
        phoneMeter.reset()
        phoneLevel = 0
        status = "Stopped"
    }

    /// Put the phone's stay-awake setting back the way it was found.
    ///
    /// shortcut: skipped if the app is force-quit, the phone keeps the setting
    /// until it is changed again; revisit if that turns out to annoy anyone.
    private func restoreStayAwake() {
        guard let stayAwake else { return }
        self.stayAwake = nil
        guard let value = Int(stayAwake.before.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        Task {
            _ = try? await adb.shellCommand(
                stayAwake.serial, "settings put global stay_on_while_plugged_in \(value)"
            )
        }
    }

    private func finish(message: String?) {
        restoreStayAwake()
        if isRecording {
            Task { await stopRecording() }
        }
        guard isRunning else { return }
        phonePlayer.stop()
        session?.stop()
        session = nil
        isRunning = false
        isConnecting = false
        renderer.flush()
        phoneMeter.reset()
        phoneLevel = 0
        status = "Stopped"
        if let message { errorMessage = message }
    }
}

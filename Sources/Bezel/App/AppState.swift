import AppKit
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
    let micRecorder = MicRecorder()

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
    var lastMicRecording: URL?
    var cameras: [CameraInfo] = []

    private var session: ScrcpySession?
    private var monitor: Task<Void, Never>?
    private var didAutoConnect = false
    private var lastDeviceLog = "unset"
    private var probedSerial = ""

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
        if ProcessInfo.processInfo.environment["BEZEL_SOURCE"] == "camera" {
            settings.source = .camera
        }
        switch ProcessInfo.processInfo.environment["BEZEL_TARGET"] {
        case "webcam": settings.target = .webcam
        case "both": settings.target = .both
        default: break
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        Log.write("app: state created")
        if settings.target == .webcam,
           let seconds = Double(ProcessInfo.processInfo.environment["BEZEL_RECORD_SECONDS"] ?? ""), seconds > 0 {
            Task { [weak self] in
                guard let self else { return }
                try? await self.startRecording()
                try? await Task.sleep(for: .seconds(seconds))
                await self.stopRecording()
            }
        }
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

    func refresh() async {
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

        let session = ScrcpySession(device: device, adb: adb)
        session.onSample = { [weak self] sample in
            Task { @MainActor in
                guard let self else { return }
                self.renderer.enqueue(sample)
                if self.isRecording {
                    self.recorder.append(sample)
                }
            }
        }
        session.onAudioConfig = { [weak self] asc in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.recorder.configureAudio(asc: asc)
            }
        }
        session.onAudioFrame = { [weak self] frame, pts in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.recorder.appendAudio(frame: frame, ptsMicros: pts)
            }
        }
        session.onSize = { [weak self] width, height in
            Task { @MainActor in
                self?.frameSize = CGSize(width: width, height: height)
            }
        }
        session.onEnd = { [weak self] message in
            Task { @MainActor in self?.finish(message: message) }
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

    func startRecording() async throws {
        guard !isRecording else { return }
        if settings.target.recordsPhone, !isRunning {
            throw RecorderError.writer("Connect the phone before recording it.")
        }

        var startedURLs: [URL] = []

        if settings.target.recordsPhone {
            // The audio format has to be registered before the first video frame
            // starts the writer, so give the device a moment to send it.
            if settings.audio != .none, session?.audioConfig == nil {
                for _ in 0..<30 where session?.audioConfig == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let url = try recorder.start(fps: settings.fps)
            if let asc = session?.audioConfig {
                recorder.configureAudio(asc: asc)
            }
            lastRecording = url
            startedURLs.append(url)
            Log.write("recording: phone \(url.path)")
        }

        if settings.target.recordsWebcam {
            do {
                let url = try await webcamRecorder.start(resolution: settings.webcamResolution, fps: settings.fps)
                lastWebcamRecording = url
                startedURLs.append(url)
            } catch {
                if !startedURLs.isEmpty {
                    Task { _ = try? await recorder.finish() }
                }
                throw error
            }
        }

        if settings.macMic {
            do {
                let url = try await micRecorder.start()
                lastMicRecording = url
                startedURLs.append(url)
            } catch {
                Log.write("mic: failed \(error.localizedDescription)")
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        }

        recordStart = Date()
        isRecording = true
        Log.write("recording: start (\(startedURLs.count) file(s))")
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordStart = nil
        var saved: [URL] = []

        if settings.target.recordsPhone {
            do {
                let url = try await recorder.finish()
                lastRecording = url
                saved.append(url)
                Log.write("recording: saved \(url.path)")
            } catch {
                Log.write("recording: phone failed \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }

        if settings.target.recordsWebcam {
            do {
                let url = try await webcamRecorder.finish()
                lastWebcamRecording = url
                saved.append(url)
                Log.write("recording: saved webcam \(url.path)")
            } catch {
                Log.write("recording: webcam failed \(error.localizedDescription)")
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
            webcamRecorder.stopSession()
        }

        if settings.macMic {
            if let url = micRecorder.stop() {
                lastMicRecording = url
                saved.append(url)
                Log.write("mic: saved \(url.path)")
            }
        }

        if !saved.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(saved)
        }
    }

    func disconnect() {
        if isRecording {
            Task { await stopRecording() }
        }
        session?.stop()
        session = nil
        isRunning = false
        isConnecting = false
        renderer.flush()
        frameSize = .zero
        status = "Stopped"
    }

    private func finish(message: String?) {
        if isRecording {
            Task { await stopRecording() }
        }
        guard isRunning else { return }
        session?.stop()
        session = nil
        isRunning = false
        isConnecting = false
        renderer.flush()
        status = "Stopped"
        if let message { errorMessage = message }
    }
}

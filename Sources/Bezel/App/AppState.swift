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

    var devices: [Device] = []
    var selectedSerial: String?
    var settings = Settings()
    var status = "Plug in a device"
    var errorMessage: String?
    var isRunning = false
    var isConnecting = false
    var frameSize = CGSize.zero
    var isRecording = false
    var recordStart: Date?
    var lastRecording: URL?

    private var session: ScrcpySession?
    private var monitor: Task<Void, Never>?
    private var didAutoConnect = false
    private var lastDeviceLog = "unset"

    init() {
        Log.write("app: state created")
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
        Log.write("refresh: start adb=\(adb.adbURL.path)")
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
                try? startRecording()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    await self?.stopRecording()
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

    func startRecording() throws {
        guard isRunning, !isRecording else { return }
        let url = try recorder.start(fps: settings.fps)
        lastRecording = url
        recordStart = Date()
        isRecording = true
        Log.write("recording: start \(url.path)")
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        recordStart = nil
        do {
            let url = try await recorder.finish()
            lastRecording = url
            Log.write("recording: saved \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Log.write("recording: failed \(error.localizedDescription)")
            errorMessage = error.localizedDescription
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

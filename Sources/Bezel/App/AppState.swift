import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    let adb = ADB()
    let renderer = PreviewRenderer()

    var devices: [Device] = []
    var selectedSerial: String?
    var settings = Settings()
    var status = "Plug in a device"
    var errorMessage: String?
    var isRunning = false
    var isConnecting = false
    var frameSize = CGSize.zero

    private var session: ScrcpySession?
    private var monitor: Task<Void, Never>?

    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    var canConnect: Bool {
        guard let device = selectedDevice else { return false }
        return device.isReady && !isConnecting
    }

    func startMonitoring() {
        guard monitor == nil else { return }
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
        } catch {
            devices = []
            selectedSerial = nil
            status = "adb unavailable"
            errorMessage = error.localizedDescription
        }
    }

    func connect() async {
        guard let device = selectedDevice, !isConnecting, !isRunning else { return }
        errorMessage = nil
        renderer.flush()
        frameSize = .zero
        isConnecting = true
        status = "Connecting…"

        let session = ScrcpySession(device: device, adb: adb)
        session.onSample = { [weak self] sample in
            Task { @MainActor in self?.renderer.enqueue(sample) }
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
        } catch {
            session.stop()
            self.session = nil
            isConnecting = false
            isRunning = false
            status = "Stopped"
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        session?.stop()
        session = nil
        isRunning = false
        isConnecting = false
        renderer.flush()
        frameSize = .zero
        status = "Stopped"
    }

    private func finish(message: String?) {
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

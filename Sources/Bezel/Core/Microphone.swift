import AVFoundation

struct MicInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Picks the microphone to record. A connected USB or Thunderbolt microphone
/// wins over the built-in one, which is muted while the lid is closed.
enum Microphone {
    static func devices() -> [MicInfo] {
        discovery().map { MicInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// A nil id means "Auto": prefer an external mic.
    static func device(id: String?) -> AVCaptureDevice? {
        let devices = discovery()
        if let id, let chosen = devices.first(where: { $0.uniqueID == id }) {
            return chosen
        }
        return devices.first { $0.uniqueID != "BuiltInMicrophoneDevice" }
            ?? AVCaptureDevice.default(for: .audio)
            ?? devices.first
    }

    private static func discovery() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

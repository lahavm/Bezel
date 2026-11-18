import AVFoundation

/// Picks the microphone to record. A connected USB or Thunderbolt microphone
/// wins over the built-in one, which is muted while the lid is closed.
enum Microphone {
    static func preferred() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        let external = devices.first { $0.uniqueID != "BuiltInMicrophoneDevice" }
        return external ?? AVCaptureDevice.default(for: .audio) ?? devices.first
    }
}

import AVFoundation

/// Picks the camera to use. An external camera wins: it keeps working while
/// the lid is closed.
enum Camera {
    static func preferred() -> AVCaptureDevice? {
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        return cameras.first { $0.deviceType == .external }
            ?? cameras.first { $0.deviceType == .builtInWideAngleCamera }
            ?? cameras.first
    }
}

import AVFoundation

/// Live Mac camera feed for the picture-in-picture overlay, so the recording
/// can be framed. The recorder keeps its own capture session.
final class WebcamPreview: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bezel.webcam.preview")
    private var deviceID: String?

    func start() {
        guard !session.isRunning else { return }
        Task { [weak self] in
            guard let self,
                  await AVCaptureDevice.requestAccess(for: .video),
                  let device = Camera.preferred() else { return }
            queue.async { [self] in
                if self.deviceID != device.uniqueID {
                    self.session.beginConfiguration()
                    for input in self.session.inputs { self.session.removeInput(input) }
                    if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                        self.session.addInput(input)
                    }
                    self.session.commitConfiguration()
                    self.deviceID = device.uniqueID
                }
                guard !self.session.isRunning else { return }
                self.session.startRunning()
                Log.write("preview: \(device.localizedName) running=\(self.session.isRunning)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            Log.write("preview: stopped")
        }
    }
}

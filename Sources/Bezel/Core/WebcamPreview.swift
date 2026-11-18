import AVFoundation
import AppKit
import CoreImage
import QuartzCore

/// Owns the one capture session for the Mac camera. The live overlay and the
/// webcam recording both read from this session, so macOS never has to open the
/// camera twice (which makes the second session reject its video output).
final class WebcamPreview: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "bezel.webcam.preview")
    private let blurQueue = DispatchQueue(label: "bezel.webcam.blur", qos: .userInitiated)
    private let sinkLock = NSLock()
    private var sink: ((CMSampleBuffer) -> Void)?
    private var deviceID: String?
    private var blur = false
    private var blurAmount: Double = 0.5
    private var lastBlurTime: CFTimeInterval = 0
    private var blurBusy = false
    private var loggedFailure = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    /// Starts the camera if needed. Returns false when access is denied or no
    /// camera exists. Safe to call repeatedly.
    func start() async -> Bool {
        if queue.sync(execute: { session.isRunning }) { return true }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            Log.write("preview: camera access denied")
            return false
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !session.isRunning else {
                    continuation.resume(returning: true)
                    return
                }
                guard let device = Camera.preferred() else {
                    Log.write("preview: no camera found")
                    continuation.resume(returning: false)
                    return
                }
                configure(device: device)
                session.startRunning()
                Log.write("preview: \(device.localizedName) running=\(session.isRunning)")
                continuation.resume(returning: session.isRunning)
            }
        }
    }

    private func configure(device: AVCaptureDevice) {
        guard deviceID != device.uniqueID else { return }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        } else {
            Log.write("preview: camera input rejected")
        }
        if session.outputs.isEmpty {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                Log.write("preview: camera rejected the video output")
            }
        }
        session.commitConfiguration()
        deviceID = device.uniqueID
    }

    /// Receives every raw camera frame. The recorder installs its writer here
    /// while recording; blur never touches what is written to disk.
    func setFrameSink(_ sink: ((CMSampleBuffer) -> Void)?) {
        sinkLock.lock()
        self.sink = sink
        sinkLock.unlock()
    }

    private var currentSink: ((CMSampleBuffer) -> Void)? {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        return sink
    }

    func setBlur(_ enabled: Bool, amount: Double = 0.5) {
        queue.async { [self] in
            blur = enabled
            blurAmount = amount
            if !enabled { loggedFailure = false }
        }
    }

    func stop() {
        queue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            displayLayer.flushAndRemoveImage()
            Log.write("preview: stopped")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Deliver the raw frame first so a slow blur pass never delays the
        // recording. Only the preview is blurred; the export blurs the webcam
        // file when it composes the picture in picture.
        currentSink?(sampleBuffer)
        display(sampleBuffer)
    }

    private func display(_ sampleBuffer: CMSampleBuffer) {
        guard blur else {
            if let copy = Self.displayCopy(sampleBuffer: sampleBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) {
                enqueue(copy)
            }
            return
        }

        // The inset is small; 15 fps is enough and keeps Vision cheap.
        let now = CACurrentMediaTime()
        guard now - lastBlurTime >= 1.0 / 15, !blurBusy else { return }
        lastBlurTime = now
        blurBusy = true
        let amount = blurAmount

        blurQueue.async { [weak self] in
            guard let self else { return }
            defer { self.queue.async { self.blurBusy = false } }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
               let image = PortraitBlur.apply(to: buffer, amount: amount),
               let rendered = PortraitBlur.render(
                    image,
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer)
               ),
               let copy = Self.displayCopy(pixelBuffer: rendered, pts: pts) {
                self.queue.async { self.enqueue(copy) }
                return
            }

            if !self.loggedFailure {
                self.loggedFailure = true
                Log.write("preview: blur unavailable, showing the plain camera")
            }
            if let copy = Self.displayCopy(sampleBuffer: sampleBuffer, pts: pts) {
                self.queue.async { self.enqueue(copy) }
            }
        }
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sample)
    }

    private static func displayCopy(sampleBuffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        ) == noErr, let copy else { return nil }
        CMSetAttachment(
            copy,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return copy
    }

    private static func displayCopy(pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        CMSetAttachment(
            sample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return sample
    }
}

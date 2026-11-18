import AVFoundation
import CoreMedia
import Foundation

enum WebcamError: LocalizedError {
    case noCamera
    case denied
    case configuration(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No Mac camera was found."
        case .denied: return "Camera access is off. Enable it in System Settings › Privacy & Security › Camera."
        case .configuration(let message): return message
        case .noFrames: return "The Mac camera sent no frames. If the lid is closed, use an external camera."
        }
    }
}

/// Records the built-in Mac camera to its own H.264 file.
/// Kept separate from the phone recording so the phone stream stays untouched.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "bezel.webcam")
    private let writeQueue = DispatchQueue(label: "bezel.webcam.writer")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var fps = 30
    private var started = false
    private var frames = 0
    private var lastPTS: CMTime = .invalid

    private(set) var url: URL?

    var isRunning: Bool {
        writeQueue.sync { writer != nil }
    }

    func start(fps: Int, directory: URL) async throws -> URL {
        Log.write("webcam: requesting camera access")
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            Log.write("webcam: access denied")
            throw WebcamError.denied
        }
        Log.write("webcam: access granted")
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        Log.write("webcam: devices \(discovery.devices.map(\.localizedName).joined(separator: ", "))")
        guard let device = Camera.preferred() else {
            throw WebcamError.noCamera
        }
        Log.write("webcam: using \(device.localizedName) (\(device.deviceType.rawValue))")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = directory.appendingPathComponent("Bezel Mac \(formatter.string(from: Date())).mp4")

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)

        session.beginConfiguration()
        let captureInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(captureInput) else {
            session.commitConfiguration()
            throw WebcamError.configuration("The capture session rejected the camera.")
        }
        session.addInput(captureInput)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw WebcamError.configuration("The capture session rejected the video output.")
        }
        session.addOutput(output)

        session.commitConfiguration()

        writeQueue.sync {
            self.writer = writer
            self.input = nil
            self.fps = fps
            self.url = fileURL
            self.started = false
            self.frames = 0
            self.lastPTS = .invalid
        }

        session.startRunning()
        let connection = output.connection(with: .video)
        Log.write("webcam: running=\(session.isRunning) connection=\(connection != nil) enabled=\(connection?.isEnabled ?? false)")
        Log.write("webcam: recording to \(fileURL.lastPathComponent)")
        return fileURL
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let seen = writeQueue.sync { frames }
        if seen == 0 { Log.write("webcam: first capture callback") }
        writeQueue.async { [self] in
            guard let writer, writer.status == .writing || writer.status == .unknown else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid else { return }

            if input == nil {
                // Encode at whatever size the camera delivers; there is no
                // reliable way to guess it from the device.
                guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                let compress: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: width * height > 1920 * 1080 ? 40_000_000 : 14_000_000,
                        AVVideoMaxKeyFrameIntervalKey: fps * 2,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ]
                ]
                let created = AVAssetWriterInput(mediaType: .video, outputSettings: compress)
                created.expectsMediaDataInRealTime = true
                guard writer.canAdd(created) else {
                    Log.write("webcam: writer rejected the video input")
                    return
                }
                writer.add(created)
                input = created
            }
            guard let input else { return }

            if !started {
                guard writer.startWriting() else {
                    Log.write("webcam: startWriting failed \(writer.error?.localizedDescription ?? "")")
                    return
                }
                writer.startSession(atSourceTime: pts)
                started = true
            }
            guard input.isReadyForMoreMediaData else { return }
            if input.append(sampleBuffer) {
                frames += 1
                lastPTS = pts
                if frames == 1 || frames % 150 == 0 {
                    Log.write("webcam: frames=\(frames)")
                }
            }
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.sync {}
            writeQueue.async { [self] in
                guard let writer, let url else {
                    continuation.resume(throwing: WebcamError.noFrames)
                    return
                }
                let input = self.input
                let captured = started && frames > 0
                self.input = nil
                self.writer = nil

                guard captured else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: WebcamError.noFrames)
                    return
                }

                input?.markAsFinished()
                writer.endSession(atSourceTime: CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 30)))
                writer.finishWriting {
                    if writer.status != .completed {
                        let detail = writer.error?.localizedDescription ?? "The camera recording could not be finished."
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(throwing: WebcamError.configuration(detail))
                    } else {
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }
}

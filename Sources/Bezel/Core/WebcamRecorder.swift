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
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "bezel.webcam")
    private let writeQueue = DispatchQueue(label: "bezel.webcam.writer")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var frames = 0
    private var lastPTS: CMTime = .invalid

    private(set) var url: URL?

    var isRunning: Bool {
        writeQueue.sync { writer != nil }
    }

    func start(resolution: Int, fps: Int, directory: URL, microphone: Bool = false) async throws -> URL {
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
        let cameras = discovery.devices
        Log.write("webcam: devices \(cameras.map(\.localizedName).joined(separator: ", "))")
        // Prefer an external camera: it keeps working with the lid closed.
        guard let device = cameras.first(where: { $0.deviceType == .external })
                ?? cameras.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? cameras.first else {
            throw WebcamError.noCamera
        }
        Log.write("webcam: using \(device.localizedName) (\(device.deviceType.rawValue))")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = directory.appendingPathComponent("Bezel Mac \(formatter.string(from: Date())).mp4")

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let width = resolution >= 2160 ? 3840 : 1920
        let height = resolution >= 2160 ? 2160 : 1080
        let bitrate = resolution >= 2160 ? 40_000_000 : 14_000_000
        let compress: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: compress)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw WebcamError.configuration("The writer rejected the camera input.") }
        writer.add(input)

        var microphoneInput: AVAssetWriterInput?
        if microphone {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) { writer.add(audio); microphoneInput = audio }
        }

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

        if microphone,
           let device = Microphone.preferred(),
           let audioDeviceInput = try? AVCaptureDeviceInput(device: device) {
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddInput(audioDeviceInput), session.canAddOutput(audioOutput) {
                session.addInput(audioDeviceInput)
                session.addOutput(audioOutput)
            } else {
                Log.write("webcam: microphone could not be attached")
            }
        }
        session.commitConfiguration()

        writeQueue.sync {
            self.writer = writer
            self.input = input
            self.audioInput = microphoneInput
            self.url = fileURL
            self.started = false
            self.frames = 0
            self.lastPTS = .invalid
        }

        session.startRunning()
        let connection = output.connection(with: .video)
        Log.write("webcam: running=\(session.isRunning) connection=\(connection != nil) enabled=\(connection?.isEnabled ?? false)")
        Log.write("webcam: recording \(width)x\(height) at \(fps) fps to \(fileURL.lastPathComponent)")
        return fileURL
    }

    private func configure(device: AVCaptureDevice, resolution: Int, fps: Int) throws {
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            writeQueue.async { [self] in
                guard started, let audioInput, audioInput.isReadyForMoreMediaData else { return }
                audioInput.append(sampleBuffer)
            }
            return
        }

        let seen = writeQueue.sync { frames }
        if seen == 0 { Log.write("webcam: first capture callback") }
        writeQueue.async { [self] in
            guard let writer, writer.status == .writing || writer.status == .unknown else { return }
            guard let input else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid else { return }

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
                let audio = self.audioInput
                let captured = started && frames > 0
                self.input = nil
                self.audioInput = nil
                self.writer = nil

                guard captured else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: WebcamError.noFrames)
                    return
                }

                input?.markAsFinished()
                audio?.markAsFinished()
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

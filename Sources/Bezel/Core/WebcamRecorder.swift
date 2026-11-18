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

/// Writes the Mac camera frames into their own H.264 file, with the chosen
/// microphone when separate files are enabled. It does not open the camera:
/// the frames come from `WebcamPreview`, which owns the only capture session.
final class WebcamRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "bezel.webcam.audio")
    private let writeQueue = DispatchQueue(label: "bezel.webcam.writer")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var fps = 30
    private var started = false
    private var frames = 0
    private var lastPTS: CMTime = .invalid
    private var sessionStartPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var audioFrames = 0
    private var micVolume: Float = 1

    private(set) var url: URL?

    var isRunning: Bool {
        writeQueue.sync { writer != nil }
    }

    func setMicVolume(_ volume: Double) {
        writeQueue.async { [self] in
            self.micVolume = Float(volume)
        }
    }

    /// Prepares the output file and starts microphone capture. Video frames are
    /// supplied by `appendVideo(_:)` from the shared camera session.
    func start(fps: Int, microphone: String?, volume: Double, directory: URL) async throws -> URL {
        var microphoneDevice: AVCaptureDevice?
        if let microphone {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw WebcamError.denied
            }
            guard let device = Microphone.device(id: microphone) else {
                throw WebcamError.configuration("The microphone was not found.")
            }
            microphoneDevice = device
            Log.write("webcam: microphone \(device.localizedName)")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = directory.appendingPathComponent("Bezel Mac \(formatter.string(from: Date())).mp4")

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        var createdAudioInput: AVAssetWriterInput?
        if microphoneDevice != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else {
                throw WebcamError.configuration("The writer rejected the microphone.")
            }
            writer.add(audio)
            createdAudioInput = audio
        }

        if let microphoneDevice {
            audioSession.beginConfiguration()
            for input in audioSession.inputs { audioSession.removeInput(input) }
            for output in audioSession.outputs { audioSession.removeOutput(output) }

            guard let captureInput = try? AVCaptureDeviceInput(device: microphoneDevice),
                  audioSession.canAddInput(captureInput) else {
                audioSession.commitConfiguration()
                throw WebcamError.configuration("The microphone could not be added.")
            }
            audioSession.addInput(captureInput)

            audioOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            guard audioSession.canAddOutput(audioOutput) else {
                audioSession.commitConfiguration()
                throw WebcamError.configuration("The microphone output could not be added.")
            }
            audioSession.addOutput(audioOutput)
            audioSession.commitConfiguration()
        }

        writeQueue.sync {
            self.writer = writer
            self.input = nil
            self.audioInput = createdAudioInput
            self.fps = fps
            self.url = fileURL
            self.started = false
            self.frames = 0
            self.lastPTS = .invalid
            self.sessionStartPTS = .invalid
            self.lastAudioPTS = .invalid
            self.audioFrames = 0
            self.micVolume = Float(volume)
        }

        if microphoneDevice != nil, !audioSession.isRunning {
            audioSession.startRunning()
        }
        Log.write("webcam: recording to \(fileURL.lastPathComponent)")
        return fileURL
    }

    /// Called on the camera's capture queue with every raw frame.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
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
                sessionStartPTS = pts
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === audioOutput else { return }
        appendAudio(sampleBuffer)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writeQueue.async { [self] in
            guard started, let audioInput, let writer, writer.status == .writing else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, pts >= sessionStartPTS, audioInput.isReadyForMoreMediaData else { return }
            guard let gained = AudioGain.adjusted(micVolume, sampleBuffer: sampleBuffer) else { return }
            if audioInput.append(gained) {
                audioFrames += 1
                lastAudioPTS = pts
                if audioFrames == 1 || audioFrames % 300 == 0 {
                    Log.write("webcam: audio frames=\(audioFrames)")
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
                var end = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 30))
                if lastAudioPTS.isValid { end = CMTimeMaximum(end, lastAudioPTS) }
                writer.endSession(atSourceTime: end)
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

    /// Stops only the microphone capture; the camera belongs to the preview.
    func stopSession() {
        if audioSession.isRunning { audioSession.stopRunning() }
        audioSession.beginConfiguration()
        for input in audioSession.inputs { audioSession.removeInput(input) }
        for output in audioSession.outputs { audioSession.removeOutput(output) }
        audioSession.commitConfiguration()
    }
}

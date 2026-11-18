import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case noSamples
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .noSamples: return "The device sent no video, so there was nothing to record."
        case .writer(let message): return message
        }
    }
}

/// Writes the scrcpy stream straight into an MP4 without re-encoding.
/// The device already produces H.264/HEVC, so samples pass through untouched.
///
/// scrcpy samples carry only a presentation timestamp, so each frame is held
/// until the next one arrives and then written with the measured duration.
final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "bezel.recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var lastAudioPTS: CMTime = .invalid
    private var sessionStartPTS: CMTime = .invalid
    private var audioFrames = 0
    private var pending: CMSampleBuffer?
    private var pendingPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var started = false
    private var hasSample = false
    private var nominalDuration = CMTime(value: 1, timescale: 60)

    private var micInput: AVAssetWriterInput?
    private var micSession: AVCaptureSession?
    private let micQueue = DispatchQueue(label: "bezel.recorder.mic")
    private var micOffset: CMTime = .invalid
    private var lastMicPTS: CMTime = .invalid
    private var micFrames = 0

    private(set) var url: URL?

    var isRunning: Bool {
        queue.sync { writer != nil }
    }

    func start(fps: Int, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let fileURL = directory.appendingPathComponent("Bezel \(formatter.string(from: Date())).mp4")

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        self.writer = writer
        self.url = fileURL
        self.pending = nil
        self.pendingPTS = .invalid
        self.lastPTS = .invalid
        self.lastAudioPTS = .invalid
        self.sessionStartPTS = .invalid
        self.audioFormat = nil
        self.audioFrames = 0
        self.micOffset = .invalid
        self.lastMicPTS = .invalid
        self.micFrames = 0
        self.started = false
        self.hasSample = false
        self.nominalDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        return fileURL
    }

    /// The device sends one AudioSpecificConfig packet before any audio frame.
    func configureAudio(asc: Data) {
        queue.async { [self] in
            guard let writer else { return }
            guard audioInput == nil else { return }
            guard writer.status == .unknown else {
                Log.write("recorder: audio config arrived too late")
                return
            }
            guard let format = AudioFrames.formatDescription(asc: asc) else {
                Log.write("recorder: unsupported audio config")
                return
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                Log.write("recorder: writer rejected the audio input")
                return
            }
            writer.add(input)
            audioInput = input
            audioFormat = format
            Log.write("recorder: audio input ready")
        }
    }

    /// Adds a second audio track with the Mac microphone to the same file.
    func startMicrophone(id: String?) throws {
        guard let writer, writer.status == .unknown else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writer("The writer rejected the microphone.") }
        writer.add(input)
        micInput = input

        let session = AVCaptureSession()
        guard let device = Microphone.device(id: id),
              let captureInput = try? AVCaptureDeviceInput(device: device) else {
            throw RecorderError.writer("No microphone was found.")
        }
        Log.write("mic: using \(device.localizedName)")
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: micQueue)
        session.beginConfiguration()
        guard session.canAddInput(captureInput), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.writer("The microphone could not be configured.")
        }
        session.addInput(captureInput)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        micSession = session
        Log.write("mic: attached to the recording")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let micInput, micInput.isReadyForMoreMediaData else { return }
        queue.async { [self] in
            guard started, sessionStartPTS.isValid else { return }
            let hostPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !micOffset.isValid {
                let hostMicros = CMTimeConvertScale(hostPTS, timescale: 1_000_000, method: .roundHalfAwayFromZero)
                micOffset = CMTimeSubtract(sessionStartPTS, hostMicros)
            }
            let pts = CMTimeAdd(hostPTS, micOffset)
            guard pts >= sessionStartPTS else { return }
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
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
            ) == noErr, let copy else { return }
            if micInput.append(copy) {
                micFrames += 1
                lastMicPTS = pts
                if micFrames == 1 || micFrames % 300 == 0 {
                    Log.write("mic: frames=\(micFrames)")
                }
            }
        }
    }

    func appendAudio(frame: Data, ptsMicros: Int64) {
        queue.async { [self] in
            guard let audioFormat, let audioInput, started, sessionStartPTS.isValid else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            let pts = CMTime(value: ptsMicros, timescale: 1_000_000)
            guard pts >= sessionStartPTS else { return }
            guard let sample = AudioFrames.sampleBuffer(frame: frame, format: audioFormat, ptsMicros: ptsMicros) else { return }
            if audioInput.append(sample) {
                audioFrames += 1
                if audioFrames == 1 || audioFrames % 500 == 0 {
                    Log.write("recorder: audio frames=\(audioFrames)")
                }
                lastAudioPTS = pts
            }
        }
    }

    func append(_ sample: CMSampleBuffer, isKeyframe: Bool) {
        queue.async { [self] in
            guard let writer, writer.status == .writing || writer.status == .unknown else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { return }
            // Recording can start mid-GOP; leading P-frames reference a picture
            // that is not in the file and make the whole track unreadable.
            if !started, !isKeyframe {
                skippedFrames += 1
                return
            }

            if input == nil {
                guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
                let created = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                created.expectsMediaDataInRealTime = true
                guard writer.canAdd(created) else {
                    Log.write("recorder: writer rejected the video input")
                    return
                }
                writer.add(created)
                input = created
            }

            if !started {
                guard writer.startWriting() else {
                    Log.write("recorder: startWriting failed \(writer.error?.localizedDescription ?? "")")
                    writer.cancelWriting()
                    return
                }
                writer.startSession(atSourceTime: pts)
                sessionStartPTS = pts
                started = true
                Log.write("recorder: started at keyframe, skipped \(skippedFrames)")
            }

            if let previous = pending, pendingPTS.isValid {
                // While the writer is busy, keep the pending frame and drop this
                // one: the first frame is the keyframe and must not be lost.
                guard input?.isReadyForMoreMediaData == true else {
                    droppedFrames += 1
                    return
                }
                let gap = CMTimeSubtract(pts, pendingPTS)
                let duration = (gap.isValid && gap > .zero && gap < CMTime(value: 2, timescale: 1)) ? gap : nominalDuration
                appendCopied(previous, duration: duration)
            }
            pending = sample
            pendingPTS = pts
            lastPTS = pts
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer, let url else {
                    continuation.resume(throwing: RecorderError.noSamples)
                    return
                }
                if let previous = pending, pendingPTS.isValid {
                    for _ in 0..<100 where input?.isReadyForMoreMediaData != true {
                        usleep(2000)
                    }
                    appendCopied(previous, duration: nominalDuration)
                }
                pending = nil

                let input = self.input
                let audio = self.audioInput
                let mic = self.micInput
                self.input = nil
                self.audioInput = nil
                self.micInput = nil
                self.writer = nil
                if let micSession = self.micSession {
                    micSession.stopRunning()
                    self.micSession = nil
                }

                guard started, hasSample, lastPTS.isValid else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: RecorderError.noSamples)
                    return
                }

                Log.write("recorder: finished, skipped \(skippedFrames), dropped \(droppedFrames)")
                input?.markAsFinished()
                audio?.markAsFinished()
                mic?.markAsFinished()
                var end = lastAudioPTS.isValid ? CMTimeMaximum(lastPTS, lastAudioPTS) : lastPTS
                if lastMicPTS.isValid { end = CMTimeMaximum(end, lastMicPTS) }
                writer.endSession(atSourceTime: CMTimeAdd(end, nominalDuration))
                writer.finishWriting {
                    if writer.status != .completed {
                        let detail = writer.error?.localizedDescription ?? "The recording could not be finished."
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(throwing: RecorderError.writer(detail))
                    } else {
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }

    private var skippedFrames = 0
    private var droppedFrames = 0

    private func appendCopied(_ sample: CMSampleBuffer, duration: CMTime) {
        guard let input, input.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        if status == noErr, let copy {
            if input.append(copy) {
                hasSample = true
            } else {
                Log.write("recorder: append rejected")
            }
        } else {
            hasSample = hasSample || input.append(sample)
        }
    }
}

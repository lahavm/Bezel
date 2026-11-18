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
final class Recorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bezel.recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pending: CMSampleBuffer?
    private var pendingPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var started = false
    private var hasSample = false
    private var nominalDuration = CMTime(value: 1, timescale: 60)

    private(set) var url: URL?

    var isRunning: Bool {
        queue.sync { writer != nil }
    }

    func start(fps: Int) throws -> URL {
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bezel", isDirectory: true)
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
        self.started = false
        self.hasSample = false
        self.nominalDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        return fileURL
    }

    func append(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard let writer, writer.status == .writing || writer.status == .unknown else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isValid else { return }

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
                started = true
            }

            if let previous = pending, pendingPTS.isValid {
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
                    appendCopied(previous, duration: nominalDuration)
                }
                pending = nil

                let input = self.input
                self.input = nil
                self.writer = nil

                guard started, hasSample, lastPTS.isValid else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: RecorderError.noSamples)
                    return
                }

                input?.markAsFinished()
                writer.endSession(atSourceTime: CMTimeAdd(lastPTS, nominalDuration))
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

    private func appendCopied(_ sample: CMSampleBuffer, duration: CMTime) {
        guard let input, input.isReadyForMoreMediaData else {
            pending = nil
            return
        }
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

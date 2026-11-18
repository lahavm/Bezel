import AVFoundation
import Foundation

enum AudioMixError: LocalizedError {
    case setup(String)

    var errorDescription: String? {
        switch self {
        case .setup(let message): return message
        }
    }
}

/// Mixes all audio tracks of a recording into one AAC track while copying the
/// video stream untouched. Used when the Mac microphone is recorded too, so the
/// result is a normal single-audio MP4 that every player understands.
enum AudioMixer {
    static func mix(_ source: URL, output: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first, !audioTracks.isEmpty else {
            return source
        }
        let duration = try await asset.load(.duration)

        let reader = try AVAssetReader(asset: asset)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw AudioMixError.setup("The video could not be read.") }
        reader.add(videoOutput)

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        audioOutput.audioMix = mix
        guard reader.canAdd(audioOutput) else { throw AudioMixError.setup("The audio could not be read.") }
        reader.add(audioOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

        let format = (videoTrack.formatDescriptions.first as! CMFormatDescription?) ?? nil
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw AudioMixError.setup("The video could not be written.") }
        writer.add(videoInput)

        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw AudioMixError.setup("The mixed audio could not be written.") }
        writer.add(audioInput)

        guard reader.startReading(), writer.startWriting() else {
            throw AudioMixError.setup(reader.error?.localizedDescription
                ?? writer.error?.localizedDescription
                ?? "The recording could not be processed.")
        }
        writer.startSession(atSourceTime: .zero)

        var videoDone = false
        var audioDone = false
        var nextVideo: CMSampleBuffer? = videoOutput.copyNextSampleBuffer()
        var nextAudio: CMSampleBuffer? = audioOutput.copyNextSampleBuffer()

        while !(videoDone && audioDone) {
            var progressed = false
            if !videoDone {
                if let sample = nextVideo, videoInput.isReadyForMoreMediaData {
                    if !videoInput.append(sample) { videoDone = true }
                    nextVideo = videoOutput.copyNextSampleBuffer()
                    progressed = true
                }
                if nextVideo == nil {
                    videoInput.markAsFinished()
                    videoDone = true
                }
            }
            if !audioDone {
                if let sample = nextAudio, audioInput.isReadyForMoreMediaData {
                    if !audioInput.append(sample) { audioDone = true }
                    nextAudio = audioOutput.copyNextSampleBuffer()
                    progressed = true
                }
                if nextAudio == nil {
                    audioInput.markAsFinished()
                    audioDone = true
                }
            }
            if !progressed { try? await Task.sleep(for: .milliseconds(2)) }
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        writer.endSession(atSourceTime: duration)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw AudioMixError.setup(writer.error?.localizedDescription ?? "The audio could not be mixed.")
        }
        Log.write("mix: wrote \(output.lastPathComponent)")
        return output
    }
}

import AVFoundation
import Foundation

enum PiPError: LocalizedError {
    case missingVideo
    case export(String)

    var errorDescription: String? {
        switch self {
        case .missingVideo: return "The picture-in-picture export had no video to use."
        case .export(let message): return message
        }
    }
}

/// Composes the Mac camera into the bottom-right corner of the phone video.
/// Runs once at stop, so live capture stays a passthrough.
enum PiPExporter {
    static func compose(phone: URL, webcam: URL, output: URL) async throws -> URL {
        let phoneAsset = AVURLAsset(url: phone)
        let webcamAsset = AVURLAsset(url: webcam)

        guard let phoneVideo = try await phoneAsset.loadTracks(withMediaType: .video).first,
              let webcamVideo = try await webcamAsset.loadTracks(withMediaType: .video).first
        else { throw PiPError.missingVideo }

        let phoneDuration = try await phoneAsset.load(.duration)
        let phoneNatural = try await phoneVideo.load(.naturalSize)
        let phoneTransform = try await phoneVideo.load(.preferredTransform)

        let oriented = CGRect(origin: .zero, size: phoneNatural).applying(phoneTransform)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let composition = AVMutableComposition()
        guard let phoneCompositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ), let webcamCompositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw PiPError.export("The composition could not be created.") }

        let range = CMTimeRange(start: .zero, duration: phoneDuration)
        try phoneCompositionTrack.insertTimeRange(range, of: phoneVideo, at: .zero)
        try webcamCompositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: min(phoneDuration, try await webcamAsset.load(.duration))),
            of: webcamVideo,
            at: .zero
        )

        for track in try await phoneAsset.loadTracks(withMediaType: .audio) {
            if let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try? compositionAudio.insertTimeRange(range, of: track, at: .zero)
            }
        }

        let webcamNatural = try await webcamVideo.load(.naturalSize)
        let webcamTransform = try await webcamVideo.load(.preferredTransform)
        let inset = renderSize.width * 0.04
        let targetWidth = renderSize.width * 0.28
        let scale = targetWidth / max(1, webcamNatural.width)
        let x = renderSize.width - targetWidth - inset
        let y = inset

        let phoneLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: phoneCompositionTrack)
        phoneLayer.setTransform(phoneTransform, at: .zero)

        let webcamLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: webcamCompositionTrack)
        let placement = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)
        webcamLayer.setTransform(webcamTransform.concatenating(placement), at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = [phoneLayer, webcamLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        let presets = await AVAssetExportSession.exportPresets(compatibleWith: composition)
        let preset = presets.contains(AVAssetExportPresetHighestQuality)
            ? AVAssetExportPresetHighestQuality
            : (presets.first ?? AVAssetExportPresetHighestQuality)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw PiPError.export("The export session could not be created.")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }

        guard session.status == .completed else {
            let error = session.error as NSError?
            let detail = "\(session.error?.localizedDescription ?? "export failed") (\(error?.domain ?? "?") \(error?.code ?? 0))"
            Log.write("pip: \(detail)")
            try? FileManager.default.removeItem(at: output)
            throw PiPError.export(detail)
        }
        Log.write("pip: composed \(output.lastPathComponent)")
        return output
    }
}

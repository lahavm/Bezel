import AVFoundation
import CoreImage
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

struct PiPOptions: Sendable {
    var shape: Settings.WebcamShape = .rounded
    var scale: Double = 0.28
    var x: Double = 0.82
    var y: Double = 0.75
    var blur = false
    var blurAmount: Double = 0.5
}

/// Composes the Mac camera into the phone video at stop. The webcam is cropped,
/// masked, optionally blurred, and placed where the preview showed it.
enum PiPExporter {
    static func compose(
        phone: URL,
        webcam: URL,
        output: URL,
        options: PiPOptions
    ) async throws -> URL {
        let phoneAsset = AVURLAsset(url: phone)
        let webcamAsset = AVURLAsset(url: webcam)

        guard let phoneVideo = try await phoneAsset.loadTracks(withMediaType: .video).first,
              let webcamVideo = try await webcamAsset.loadTracks(withMediaType: .video).first
        else {
            let phoneVideos = try await phoneAsset.loadTracks(withMediaType: .video).count
            let webcamVideos = try await webcamAsset.loadTracks(withMediaType: .video).count
            Log.write("pip: no video (phone=\(phoneVideos) webcam=\(webcamVideos))")
            throw PiPError.missingVideo
        }

        let phoneTrackRange = try await phoneVideo.load(.timeRange)
        let phoneDuration = phoneTrackRange.duration
        let phoneNatural = try await phoneVideo.load(.naturalSize)
        let phoneTransform = try await phoneVideo.load(.preferredTransform)
        let webcamTransform = try await webcamVideo.load(.preferredTransform)
        let webcamDuration = try await webcamAsset.load(.duration)
        let phoneFrameRate = try await phoneVideo.load(.nominalFrameRate)

        let oriented = CGRect(origin: .zero, size: phoneNatural).applying(phoneTransform)
        let renderSize = CGSize(width: max(1, abs(oriented.width)), height: max(1, abs(oriented.height)))

        let composition = AVMutableComposition()
        guard let phoneCompositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ), let webcamCompositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw PiPError.export("The composition could not be created.") }

        // Only compose over the phone video itself. The asset can be longer
        // when audio outlasts the last frame, and asking the compositor for a
        // frame that does not exist makes the whole export fail.
        let range = CMTimeRange(start: .zero, duration: phoneDuration)
        try phoneCompositionTrack.insertTimeRange(range, of: phoneVideo, at: .zero)
        try webcamCompositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTimeMinimum(phoneDuration, webcamDuration)),
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

        let instruction = PiPInstruction(
            timeRange: range,
            phoneTrackID: phoneCompositionTrack.trackID,
            webcamTrackID: webcamCompositionTrack.trackID,
            renderSize: renderSize,
            phoneTransform: phoneTransform,
            webcamTransform: webcamTransform,
            options: options
        )

        let sourceRate = phoneFrameRate > 0 ? Double(phoneFrameRate) : 60
        let frameRate = min(60, max(30, sourceRate.rounded()))
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = PiPCompositor.self

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

/// Carries the layout choices into the compositor and keeps the mask, which
/// never changes during an export, so it is only drawn once.
final class PiPInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let phoneTrackID: CMPersistentTrackID
    let webcamTrackID: CMPersistentTrackID
    let renderSize: CGSize
    let phoneTransform: CGAffineTransform
    let webcamTransform: CGAffineTransform
    let options: PiPOptions
    let targetRect: CGRect
    let maskImage: CIImage?

    init(
        timeRange: CMTimeRange,
        phoneTrackID: CMPersistentTrackID,
        webcamTrackID: CMPersistentTrackID,
        renderSize: CGSize,
        phoneTransform: CGAffineTransform,
        webcamTransform: CGAffineTransform,
        options: PiPOptions
    ) {
        self.timeRange = timeRange
        self.phoneTrackID = phoneTrackID
        self.webcamTrackID = webcamTrackID
        self.renderSize = renderSize
        self.phoneTransform = phoneTransform
        self.webcamTransform = webcamTransform
        self.options = options
        self.requiredSourceTrackIDs = [
            NSNumber(value: phoneTrackID),
            NSNumber(value: webcamTrackID)
        ]

        let width = renderSize.width * options.scale
        let height = options.shape.isSquare ? width : width * 9 / 16
        let margin = renderSize.width * 0.02
        let wantedX = CGFloat(options.x) * renderSize.width
        let wantedY = (1 - CGFloat(options.y)) * renderSize.height
        let centerX = min(renderSize.width - width / 2 - margin, max(width / 2 + margin, wantedX))
        let centerY = min(renderSize.height - height / 2 - margin, max(height / 2 + margin, wantedY))
        let rect = CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
        self.targetRect = rect
        self.maskImage = Self.makeMask(renderSize: renderSize, rect: rect, shape: options.shape)
        super.init()
    }

    private static func makeMask(
        renderSize: CGSize,
        rect: CGRect,
        shape: Settings.WebcamShape
    ) -> CIImage? {
        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        switch shape {
        case .circle:
            context.fillEllipse(in: rect)
        case .rounded:
            let radius = rect.width * 0.06
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.fillPath()
        case .rectangle:
            context.fill(rect)
        case .heart:
            context.addPath(HeartPath.cgPath(in: rect, flipped: true))
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
    }
}

final class PiPCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext()

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? PiPInstruction else {
            request.finish(with: PiPError.missingVideo)
            return
        }
        guard let destination = request.renderContext.newPixelBuffer() else {
            request.finish(with: PiPError.export("The renderer ran out of buffers."))
            return
        }

        // A static phone screen can leave a gap at the end of the video track.
        // Fill it with black instead of failing the entire export.
        let bounds = CGRect(origin: .zero, size: instruction.renderSize)
        let phone = request.sourceFrame(byTrackID: instruction.phoneTrackID)
            .map { phoneImage($0, instruction: instruction) }
            ?? CIImage(color: .black).cropped(to: bounds)
        var output = phone
        if let webcamBuffer = request.sourceFrame(byTrackID: instruction.webcamTrackID),
           let webcam = webcamImage(webcamBuffer, instruction: instruction) {
            output = webcam.composited(over: phone)
        }

        context.render(
            output.cropped(to: bounds),
            to: destination,
            bounds: bounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        request.finish(withComposedVideoFrame: destination)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func phoneImage(_ buffer: CVPixelBuffer, instruction: PiPInstruction) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: instruction.phoneTransform)
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
        return image.cropped(to: CGRect(origin: .zero, size: instruction.renderSize))
    }

    private func webcamImage(_ buffer: CVPixelBuffer, instruction: PiPInstruction) -> CIImage? {
        var source = CIImage(cvPixelBuffer: buffer)
        if instruction.options.blur,
           let sharp = PortraitBlur.apply(to: buffer, amount: instruction.options.blurAmount, quality: .balanced) {
            source = sharp
        }
        source = source.transformed(by: instruction.webcamTransform)
        source = source.transformed(by: CGAffineTransform(
            translationX: -source.extent.origin.x,
            y: -source.extent.origin.y
        ))
        guard source.extent.width > 0, source.extent.height > 0 else { return nil }

        let rect = instruction.targetRect
        let scale = max(rect.width / source.extent.width, rect.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: scaled.extent.midX - rect.width / 2,
            y: scaled.extent.midY - rect.height / 2,
            width: rect.width,
            height: rect.height
        )
        let cropped = scaled.cropped(to: crop)
        let positioned = cropped.transformed(by: CGAffineTransform(
            translationX: rect.minX - crop.minX,
            y: rect.minY - crop.minY
        ))

        let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
        let clear = CIImage(color: .clear).cropped(to: renderRect)
        let padded = positioned.composited(over: clear)
        guard let mask = instruction.maskImage else { return padded }
        return padded
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ])
            .cropped(to: renderRect)
    }
}

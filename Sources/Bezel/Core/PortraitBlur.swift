import AVFoundation
import CoreImage
import Vision

/// Keeps the person sharp and blurs what is behind them. Used by the live
/// preview and by the picture-in-picture export so both look the same.
enum PortraitBlur {
    private static let context = CIContext()

    static func apply(
        to pixelBuffer: CVPixelBuffer,
        amount: Double = 0.5,
        quality: VNGeneratePersonSegmentationRequest.QualityLevel = .fast
    ) -> CIImage? {
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        request.usesCPUOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }

        let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let scaleX = input.extent.width / max(1, mask.extent.width)
        let scaleY = input.extent.height / max(1, mask.extent.height)
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let factor = CGFloat(max(0.05, min(1.0, amount)))
        let radius = max(2, input.extent.width * (0.008 + 0.08 * factor))
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)

        return input
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: scaledMask
            ])
            .cropped(to: input.extent)
    }

    static func render(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        context.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return buffer
    }
}

import AppKit
import AVFoundation
import CoreImage
import Foundation
import ImageIO

/// Saves the frame the preview is currently showing as a PNG. No extra decode
/// pass and no partial-GOP problem, exactly like a scrcpy screenshot.
final class Snapshotter: @unchecked Sendable {
    private let context = CIContext()

    func save(_ pixelBuffer: CVPixelBuffer, into directory: URL) throws -> URL {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw RecorderError.writer("The frame could not be converted.")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = directory.appendingPathComponent("Bezel Shot \(stamp).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Bezel Shot \(stamp) \(suffix).png")
            suffix += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw RecorderError.writer("The screenshot file could not be created.")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RecorderError.writer("The screenshot could not be written.")
        }
        Log.write("screenshot: saved \(url.lastPathComponent)")
        return url
    }
}

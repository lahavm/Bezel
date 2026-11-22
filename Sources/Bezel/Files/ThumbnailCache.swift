import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small, lazy, on-disk thumbnails for remote files. Never blocks the browser.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private let folder: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("Bezel/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    func image(for item: FileItem, backend: any FileBackend, maxPixel: CGFloat = 320) async -> NSImage? {
        guard item.type.conforms(to: .image) || item.type.conforms(to: .pdf) else { return nil }
        guard item.size < 60_000_000 else { return nil }

        let key = Self.key(for: item, backend: backend, maxPixel: maxPixel)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let file = folder.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        let sourceURL: URL
        var temporary: URL?
        if backend.isRemote {
            temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("bezel-thumb-\(UUID().uuidString)")
            guard let temporary else { return nil }
            defer { Task.detached { try? FileManager.default.removeItem(at: temporary) } }
            do {
                try await backend.download(item.path, to: temporary, onBytes: { _ in })
            } catch {
                return nil
            }
            sourceURL = temporary
        } else {
            sourceURL = URL(fileURLWithPath: item.path)
        }

        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  imageSource,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                      kCGImageSourceThumbnailMaxPixelSize as String: Int(maxPixel),
                      kCGImageSourceCreateThumbnailWithTransform as String: true,
                      kCGImageSourceShouldCacheImmediately as String: true
                  ] as CFDictionary
              )
        else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))
        memory.setObject(image, forKey: key as NSString)
        if let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, cgImage, [
                kCGImageDestinationLossyCompressionQuality as String: 0.8
            ] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return image
    }

    private static func key(for item: FileItem, backend: any FileBackend, maxPixel: CGFloat) -> String {
        let seed = "\(backend.id)|\(item.path)|\(item.size)|\(item.modified.timeIntervalSince1970)|\(Int(maxPixel))"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

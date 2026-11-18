import AppKit
import CoreGraphics
import Foundation

private let colorSpace = CGColorSpaceCreateDeviceRGB()

private func makeGradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(
        colorsSpace: colorSpace,
        colors: colors.map(\.cgColor) as CFArray,
        locations: locations
    )
}

private func strokeGradient(
    _ ctx: CGContext,
    path: CGPath,
    colors: [NSColor],
    locations: [CGFloat],
    lineWidth: CGFloat,
    from: CGPoint,
    to: CGPoint
) {
    guard let gradient = makeGradient(colors, locations) else { return }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(lineWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
    ctx.restoreGState()
}

/// A graphite squircle, a dark glass phone with a luminous bezel, and one mint
/// camera inset. Flat gradients and negative space instead of hardware detail,
/// so the mark stays clean at 16 points and matches macOS 26.
func drawBezelIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: CGSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    let scale = size / 1024.0
    ctx.saveGState()

    // Standard macOS squircle grid: 824 × 824 on a 1024 canvas.
    let squircleRect = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: 185 * scale,
        cornerHeight: 185 * scale,
        transform: nil
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -20 * scale),
        blur: 38 * scale,
        color: NSColor.black.withAlphaComponent(0.45).cgColor
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Graphite body.
    if let background = makeGradient([
        NSColor(red: 0.145, green: 0.16, blue: 0.19, alpha: 1),
        NSColor(red: 0.075, green: 0.083, blue: 0.10, alpha: 1),
        NSColor(red: 0.032, green: 0.036, blue: 0.048, alpha: 1)
    ], [0, 0.5, 1]) {
        ctx.drawLinearGradient(
            background,
            start: CGPoint(x: size * 0.5, y: squircleRect.maxY),
            end: CGPoint(x: size * 0.5, y: squircleRect.minY),
            options: []
        )
    }

    // Cool light behind the phone.
    if let glow = makeGradient([
        NSColor(red: 0.18, green: 0.80, blue: 0.78, alpha: 0.18),
        NSColor(red: 0.18, green: 0.80, blue: 0.78, alpha: 0)
    ], [0, 1]) {
        let center = CGPoint(x: size * 0.5, y: size * 0.53)
        ctx.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 20 * scale,
            endCenter: center,
            endRadius: 430 * scale,
            options: []
        )
    }

    // Phone body.
    let phoneWidth = 424 * scale
    let phoneHeight = 664 * scale
    let phoneRect = CGRect(
        x: (size - phoneWidth) / 2,
        y: (size - phoneHeight) / 2 + 6 * scale,
        width: phoneWidth,
        height: phoneHeight
    )
    let phoneCorner = 104 * scale
    let phonePath = CGPath(
        roundedRect: phoneRect,
        cornerWidth: phoneCorner,
        cornerHeight: phoneCorner,
        transform: nil
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -18 * scale),
        blur: 34 * scale,
        color: NSColor.black.withAlphaComponent(0.55).cgColor
    )
    ctx.addPath(phonePath)
    ctx.setFillColor(NSColor(red: 0.02, green: 0.025, blue: 0.035, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    strokeGradient(
        ctx,
        path: phonePath,
        colors: [
            NSColor.white.withAlphaComponent(0.30),
            NSColor.white.withAlphaComponent(0.10),
            NSColor.white.withAlphaComponent(0.03)
        ],
        locations: [0, 0.55, 1],
        lineWidth: 3 * scale,
        from: CGPoint(x: size * 0.5, y: phoneRect.maxY),
        to: CGPoint(x: size * 0.5, y: phoneRect.minY)
    )

    // Display.
    let screenRect = phoneRect.insetBy(dx: 20 * scale, dy: 20 * scale)
    let screenCorner = 88 * scale
    let screenPath = CGPath(
        roundedRect: screenRect,
        cornerWidth: screenCorner,
        cornerHeight: screenCorner,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()

    if let screen = makeGradient([
        NSColor(red: 0.035, green: 0.15, blue: 0.21, alpha: 1),
        NSColor(red: 0.035, green: 0.32, blue: 0.39, alpha: 1),
        NSColor(red: 0.075, green: 0.62, blue: 0.62, alpha: 1)
    ], [0, 0.55, 1]) {
        ctx.drawLinearGradient(
            screen,
            start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
            end: CGPoint(x: screenRect.maxX, y: screenRect.minY),
            options: []
        )
    }

    if let bloom = makeGradient([
        NSColor(red: 0.55, green: 0.98, blue: 0.90, alpha: 0.38),
        NSColor(red: 0.55, green: 0.98, blue: 0.90, alpha: 0)
    ], [0, 1]) {
        let center = CGPoint(x: screenRect.maxX - 120 * scale, y: screenRect.minY + 120 * scale)
        ctx.drawRadialGradient(
            bloom,
            startCenter: center,
            startRadius: 4 * scale,
            endCenter: center,
            endRadius: 300 * scale,
            options: []
        )
    }

    ctx.addPath(screenPath)
    ctx.setLineWidth(2 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.strokePath()

    ctx.restoreGState()

    // Camera inset.
    let camRadius = 108 * scale
    let camCenter = CGPoint(
        x: screenRect.maxX - 26 * scale,
        y: screenRect.minY + 64 * scale
    )
    let camRect = CGRect(
        x: camCenter.x - camRadius,
        y: camCenter.y - camRadius,
        width: camRadius * 2,
        height: camRadius * 2
    )

    if let halo = makeGradient([
        NSColor(red: 0.55, green: 0.98, blue: 0.90, alpha: 0.20),
        NSColor(red: 0.55, green: 0.98, blue: 0.90, alpha: 0)
    ], [0, 1]) {
        ctx.drawRadialGradient(
            halo,
            startCenter: camCenter,
            startRadius: camRadius * 0.8,
            endCenter: camCenter,
            endRadius: camRadius * 2.1,
            options: []
        )
    }

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * scale),
        blur: 26 * scale,
        color: NSColor.black.withAlphaComponent(0.55).cgColor
    )
    ctx.addEllipse(in: camRect)
    ctx.setFillColor(NSColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    strokeGradient(
        ctx,
        path: CGPath(ellipseIn: camRect, transform: nil),
        colors: [
            NSColor(red: 0.82, green: 1.0, blue: 0.94, alpha: 1),
            NSColor(red: 0.25, green: 0.87, blue: 0.78, alpha: 1),
            NSColor(red: 0.04, green: 0.45, blue: 0.42, alpha: 1)
        ],
        locations: [0, 0.5, 1],
        lineWidth: 12 * scale,
        from: CGPoint(x: camCenter.x, y: camRect.maxY),
        to: CGPoint(x: camCenter.x, y: camRect.minY)
    )

    let lensRect = camRect.insetBy(dx: 30 * scale, dy: 30 * scale)
    ctx.saveGState()
    ctx.addEllipse(in: lensRect)
    ctx.clip()
    if let lens = makeGradient([
        NSColor(red: 0.07, green: 0.19, blue: 0.25, alpha: 1),
        NSColor(red: 0.01, green: 0.03, blue: 0.055, alpha: 1)
    ], [0, 1]) {
        ctx.drawRadialGradient(
            lens,
            startCenter: CGPoint(x: camCenter.x - 24 * scale, y: camCenter.y + 24 * scale),
            startRadius: 4 * scale,
            endCenter: camCenter,
            endRadius: camRadius,
            options: []
        )
    }
    ctx.restoreGState()

    // One small specular, no glossy reflection.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.fillEllipse(in: CGRect(
        x: camCenter.x - 36 * scale,
        y: camCenter.y + 22 * scale,
        width: 18 * scale,
        height: 18 * scale
    ))

    // Squircle edge.
    strokeGradient(
        ctx,
        path: squirclePath,
        colors: [
            NSColor.white.withAlphaComponent(0.30),
            NSColor.white.withAlphaComponent(0.08),
            NSColor.white.withAlphaComponent(0.02)
        ],
        locations: [0, 0.55, 1],
        lineWidth: 2.5 * scale,
        from: CGPoint(x: size * 0.5, y: squircleRect.maxY),
        to: CGPoint(x: size * 0.5, y: squircleRect.minY)
    )

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

private func pngData(from image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = CGSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

func generateAppIcon() {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let iconset = root.appendingPathComponent("build/AppIcon.iconset")
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")

    try? FileManager.default.removeItem(at: iconset)
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let master = drawBezelIcon(size: 1024)
    if let preview = pngData(from: master, pixels: 1024) {
        try? preview.write(to: root.appendingPathComponent("build/icon-preview.png"))
    }

    let variants: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for (name, pixels) in variants {
        guard let data = pngData(from: master, pixels: pixels) else { continue }
        try? data.write(to: iconset.appendingPathComponent(name))
    }

    try? FileManager.default.removeItem(at: icns)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try? iconutil.run()
    iconutil.waitUntilExit()
    print("Wrote \(icns.path)")
}

generateAppIcon()

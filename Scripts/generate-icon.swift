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

/// A graphite squircle, a phone with a polished bezel, and the camera inset.
/// Kept as drawing code so every size of the .icns stays crisp.
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
    let cornerRadius = 185 * scale
    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Contact shadow under the icon.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -22 * scale),
        blur: 40 * scale,
        color: NSColor.black.withAlphaComponent(0.5).cgColor
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(red: 0.035, green: 0.04, blue: 0.06, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Graphite body.
    if let background = makeGradient([
        NSColor(red: 0.17, green: 0.19, blue: 0.24, alpha: 1),
        NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1),
        NSColor(red: 0.045, green: 0.05, blue: 0.07, alpha: 1)
    ], [0, 0.45, 1]) {
        ctx.drawLinearGradient(
            background,
            start: CGPoint(x: size * 0.5, y: squircleRect.maxY),
            end: CGPoint(x: size * 0.5, y: squircleRect.minY),
            options: []
        )
    }

    // Soft light falling from the top left.
    if let sheen = makeGradient([
        NSColor.white.withAlphaComponent(0.08),
        NSColor.white.withAlphaComponent(0)
    ], [0, 1]) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: squircleRect.minX, y: squircleRect.maxY),
            end: CGPoint(x: squircleRect.maxX, y: squircleRect.minY - 120 * scale),
            options: []
        )
    }

    // Aqua light behind the phone.
    if let glow = makeGradient([
        NSColor(red: 0.24, green: 0.68, blue: 0.86, alpha: 0.22),
        NSColor(red: 0.24, green: 0.68, blue: 0.86, alpha: 0)
    ], [0, 1]) {
        let center = CGPoint(x: size * 0.5, y: size * 0.54)
        ctx.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 30 * scale,
            endCenter: center,
            endRadius: 410 * scale,
            options: []
        )
    }

    // Phone chassis.
    let phoneWidth = 436 * scale
    let phoneHeight = 672 * scale
    let phoneRect = CGRect(
        x: (size - phoneWidth) / 2,
        y: (size - phoneHeight) / 2 + 4 * scale,
        width: phoneWidth,
        height: phoneHeight
    )
    let phoneCorner = 64 * scale
    let chassisPath = CGPath(
        roundedRect: phoneRect,
        cornerWidth: phoneCorner,
        cornerHeight: phoneCorner,
        transform: nil
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -16 * scale),
        blur: 26 * scale,
        color: NSColor.black.withAlphaComponent(0.65).cgColor
    )
    ctx.addPath(chassisPath)
    ctx.setFillColor(NSColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Polished metal edge.
    ctx.saveGState()
    ctx.addPath(chassisPath)
    ctx.setLineWidth(5 * scale)
    if let metal = makeGradient([
        NSColor(red: 0.72, green: 0.76, blue: 0.82, alpha: 0.9),
        NSColor(red: 0.30, green: 0.33, blue: 0.39, alpha: 0.75),
        NSColor(red: 0.14, green: 0.15, blue: 0.18, alpha: 0.6)
    ], [0, 0.45, 1]) {
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            metal,
            start: CGPoint(x: size * 0.5, y: phoneRect.maxY),
            end: CGPoint(x: size * 0.5, y: phoneRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // The bezel margin around the display.
    let bezelInset = 16 * scale
    let screenRect = phoneRect.insetBy(dx: bezelInset, dy: bezelInset)
    let screenCorner = phoneCorner - 10 * scale
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
        NSColor(red: 0.035, green: 0.13, blue: 0.25, alpha: 1),
        NSColor(red: 0.035, green: 0.34, blue: 0.45, alpha: 1),
        NSColor(red: 0.20, green: 0.66, blue: 0.72, alpha: 1),
        NSColor(red: 0.55, green: 0.90, blue: 0.89, alpha: 1)
    ], [0, 0.42, 0.8, 1]) {
        ctx.drawLinearGradient(
            screen,
            start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
            end: CGPoint(x: screenRect.maxX, y: screenRect.minY),
            options: []
        )
    }

    // Cool bloom in the lower right of the display.
    if let bloom = makeGradient([
        NSColor(red: 0.55, green: 0.95, blue: 0.95, alpha: 0.35),
        NSColor(red: 0.55, green: 0.95, blue: 0.95, alpha: 0)
    ], [0, 1]) {
        let center = CGPoint(
            x: screenRect.maxX - 80 * scale,
            y: screenRect.minY + 110 * scale
        )
        ctx.drawRadialGradient(
            bloom,
            startCenter: center,
            startRadius: 5 * scale,
            endCenter: center,
            endRadius: 330 * scale,
            options: []
        )
    }

    // Glass reflection.
    let reflection = CGMutablePath()
    reflection.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
    reflection.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY - screenRect.height * 0.46))
    reflection.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.minY))
    reflection.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.minY + screenRect.height * 0.30))
    reflection.closeSubpath()
    ctx.addPath(reflection)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.fillPath()

    // A second, narrower glint.
    let glint = CGMutablePath()
    glint.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY - 30 * scale))
    glint.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY - screenRect.height * 0.55))
    glint.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY - screenRect.height * 0.42))
    glint.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.maxY - 10 * scale))
    glint.closeSubpath()
    ctx.addPath(glint)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
    ctx.fillPath()

    // Inner display rim.
    ctx.addPath(screenPath)
    ctx.setLineWidth(2 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    ctx.strokePath()

    // Dynamic Island.
    let islandWidth = 88 * scale
    let islandHeight = 22 * scale
    let islandRect = CGRect(
        x: (size - islandWidth) / 2,
        y: screenRect.maxY - 30 * scale,
        width: islandWidth,
        height: islandHeight
    )
    ctx.addPath(CGPath(
        roundedRect: islandRect,
        cornerWidth: islandHeight / 2,
        cornerHeight: islandHeight / 2,
        transform: nil
    ))
    ctx.setFillColor(NSColor(red: 0.015, green: 0.02, blue: 0.03, alpha: 0.98).cgColor)
    ctx.fillPath()

    let islandLens = CGRect(
        x: islandRect.maxX - 28 * scale,
        y: islandRect.midY - 3.5 * scale,
        width: 7 * scale,
        height: 7 * scale
    )
    ctx.setFillColor(NSColor(red: 0.10, green: 0.25, blue: 0.34, alpha: 1).cgColor)
    ctx.fillEllipse(in: islandLens)

    ctx.restoreGState() // screen clip

    // Camera badge, the signature inset.
    let camRadius = 108 * scale
    let camCenter = CGPoint(
        x: screenRect.maxX - 4 * scale,
        y: screenRect.minY + 40 * scale
    )
    let camRect = CGRect(
        x: camCenter.x - camRadius,
        y: camCenter.y - camRadius,
        width: camRadius * 2,
        height: camRadius * 2
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * scale),
        blur: 20 * scale,
        color: NSColor.black.withAlphaComponent(0.6).cgColor
    )
    ctx.addEllipse(in: camRect)
    ctx.setFillColor(NSColor(red: 0.05, green: 0.06, blue: 0.085, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: camRect)
    ctx.setLineWidth(5 * scale)
    if let rim = makeGradient([
        NSColor.white.withAlphaComponent(0.72),
        NSColor.white.withAlphaComponent(0.34),
        NSColor.white.withAlphaComponent(0.10)
    ], [0, 0.5, 1]) {
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            rim,
            start: CGPoint(x: camCenter.x, y: camRect.maxY),
            end: CGPoint(x: camCenter.x, y: camRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.saveGState()
    let lensRect = camRect.insetBy(dx: 8 * scale, dy: 8 * scale)
    ctx.addEllipse(in: lensRect)
    ctx.clip()

    if let lens = makeGradient([
        NSColor(red: 0.06, green: 0.16, blue: 0.28, alpha: 1),
        NSColor(red: 0.015, green: 0.035, blue: 0.075, alpha: 1)
    ], [0, 1]) {
        ctx.drawRadialGradient(
            lens,
            startCenter: CGPoint(x: camCenter.x - 26 * scale, y: camCenter.y + 26 * scale),
            startRadius: 5 * scale,
            endCenter: camCenter,
            endRadius: camRadius,
            options: []
        )
    }

    let irisRect = lensRect.insetBy(dx: 26 * scale, dy: 26 * scale)
    ctx.setLineWidth(3 * scale)
    ctx.setStrokeColor(NSColor(red: 0.30, green: 0.72, blue: 0.86, alpha: 0.5).cgColor)
    ctx.strokeEllipse(in: irisRect)

    let apertureRect = irisRect.insetBy(dx: 18 * scale, dy: 18 * scale)
    ctx.setFillColor(NSColor(red: 0.01, green: 0.025, blue: 0.055, alpha: 1).cgColor)
    ctx.fillEllipse(in: apertureRect)

    let specular = CGRect(
        x: camCenter.x - 42 * scale,
        y: camCenter.y + 20 * scale,
        width: 27 * scale,
        height: 17 * scale
    )
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
    ctx.fillEllipse(in: specular)
    ctx.restoreGState()

    // Squircle bevel.
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(2.5 * scale)
    if let rim = makeGradient([
        NSColor.white.withAlphaComponent(0.38),
        NSColor.white.withAlphaComponent(0.10),
        NSColor.white.withAlphaComponent(0.03)
    ], [0, 0.55, 1]) {
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            rim,
            start: CGPoint(x: size * 0.5, y: squircleRect.maxY),
            end: CGPoint(x: size * 0.5, y: squircleRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

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

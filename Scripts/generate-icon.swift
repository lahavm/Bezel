import AppKit
import CoreGraphics
import Foundation

func drawBezelIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: CGSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    ctx.saveGState()

    // Coordinate space: (0,0) bottom-left, (size, size) top-right.
    let scale = size / 1024.0

    // Standard macOS squircle grid: 824x824 at 1024 canvas, corner radius 185
    let squircleRect = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let cornerRadius = 185 * scale

    // Outer Drop Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * scale), blur: 36 * scale, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Base Squircle Background Gradient (Deep Space Navy to Obsidian)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.14, green: 0.16, blue: 0.22, alpha: 1.0).cgColor,
        NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1.0).cgColor
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: size * 0.5, y: squircleRect.maxY), end: CGPoint(x: size * 0.5, y: squircleRect.minY), options: [])

    // Subtle Radial Ambient Glow behind the phone
    let glowColors = [
        NSColor(red: 0.35, green: 0.45, blue: 0.95, alpha: 0.25).cgColor,
        NSColor(red: 0.35, green: 0.45, blue: 0.95, alpha: 0.0).cgColor
    ] as CFArray
    let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glowGradient, startCenter: CGPoint(x: size * 0.5, y: size * 0.52), startRadius: 20 * scale, endCenter: CGPoint(x: size * 0.5, y: size * 0.52), endRadius: 360 * scale, options: [])

    // --- Phone "Bezel" Chassis ---
    // Outer phone body (Chassis)
    let phoneWidth: CGFloat = 430 * scale
    let phoneHeight: CGFloat = 650 * scale
    let phoneRect = CGRect(x: (size - phoneWidth) / 2, y: (size - phoneHeight) / 2 + 10 * scale, width: phoneWidth, height: phoneHeight)
    let phoneCorner: CGFloat = 58 * scale

    // Phone shadow inside icon
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 24 * scale, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    let chassisPath = CGPath(roundedRect: phoneRect, cornerWidth: phoneCorner, cornerHeight: phoneCorner, transform: nil)
    ctx.addPath(chassisPath)
    ctx.setFillColor(NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Chassis metallic border gradient
    ctx.saveGState()
    ctx.addPath(chassisPath)
    let chassisStroke = [
        NSColor(red: 0.55, green: 0.60, blue: 0.70, alpha: 0.8).cgColor,
        NSColor(red: 0.20, green: 0.22, blue: 0.28, alpha: 0.6).cgColor
    ] as CFArray
    let strokeGradient = CGGradient(colorsSpace: colorSpace, colors: chassisStroke, locations: [0.0, 1.0])!
    ctx.setLineWidth(5 * scale)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(strokeGradient, start: CGPoint(x: size * 0.5, y: phoneRect.maxY), end: CGPoint(x: size * 0.5, y: phoneRect.minY), options: [])
    ctx.restoreGState()

    // The Physical Bezel Margin (Thin edge around screen)
    let bezelInset: CGFloat = 14 * scale
    let screenRect = phoneRect.insetBy(dx: bezelInset, dy: bezelInset)
    let screenCorner: CGFloat = phoneCorner - bezelInset * 0.85
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenCorner, cornerHeight: screenCorner, transform: nil)

    // Screen Display Gradient (Vibrant high-res mirrored screen)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()

    let screenColors = [
        NSColor(red: 0.12, green: 0.55, blue: 0.98, alpha: 1.0).cgColor, // Electric Cyan/Blue
        NSColor(red: 0.48, green: 0.24, blue: 0.92, alpha: 1.0).cgColor, // Vibrant Violet
        NSColor(red: 0.95, green: 0.32, blue: 0.54, alpha: 1.0).cgColor  // Coral Pink
    ] as CFArray
    let screenGradient = CGGradient(colorsSpace: colorSpace, colors: screenColors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(screenGradient, start: CGPoint(x: screenRect.minX, y: screenRect.maxY), end: CGPoint(x: screenRect.maxX, y: screenRect.minY), options: [])

    // Glass Screen Sheen / Diagonal Reflection
    let sheenPath = CGMutablePath()
    sheenPath.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
    sheenPath.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY - screenRect.height * 0.45))
    sheenPath.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.minY))
    sheenPath.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.minY + screenRect.height * 0.45))
    sheenPath.closeSubpath()
    ctx.addPath(sheenPath)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.fillPath()

    // Dynamic Island / Speaker Pill at top of phone screen
    let notchWidth: CGFloat = 84 * scale
    let notchHeight: CGFloat = 20 * scale
    let notchRect = CGRect(x: (size - notchWidth) / 2, y: screenRect.maxY - 28 * scale, width: notchWidth, height: notchHeight)
    let notchPath = CGPath(roundedRect: notchRect, cornerWidth: notchHeight / 2, cornerHeight: notchHeight / 2, transform: nil)
    ctx.addPath(notchPath)
    ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.95).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Signature Camera Overlay (Picture-in-Picture) ---
    // Floating camera circle overlapping bottom-right of the screen
    let camRadius: CGFloat = 110 * scale
    let camCenter = CGPoint(x: screenRect.maxX - 20 * scale, y: screenRect.minY + 45 * scale)
    let camRect = CGRect(x: camCenter.x - camRadius, y: camCenter.y - camRadius, width: camRadius * 2, height: camRadius * 2)

    // Camera circle drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 20 * scale, color: NSColor.black.withAlphaComponent(0.55).cgColor)
    ctx.addEllipse(in: camRect)
    ctx.setFillColor(NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Camera outer ring (White translucent border)
    ctx.saveGState()
    ctx.addEllipse(in: camRect)
    ctx.setLineWidth(5 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Camera Lens interior
    ctx.saveGState()
    let innerCamRect = camRect.insetBy(dx: 7 * scale, dy: 7 * scale)
    ctx.addEllipse(in: innerCamRect)
    ctx.clip()

    // Lens deep sapphire gradient
    let lensColors = [
        NSColor(red: 0.08, green: 0.15, blue: 0.28, alpha: 1.0).cgColor,
        NSColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 1.0).cgColor
    ] as CFArray
    let lensGradient = CGGradient(colorsSpace: colorSpace, colors: lensColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(lensGradient, startCenter: CGPoint(x: camCenter.x - 25 * scale, y: camCenter.y + 25 * scale), startRadius: 5 * scale, endCenter: camCenter, endRadius: camRadius, options: [])

    // Lens iris aperture reflection
    let apertureRect = innerCamRect.insetBy(dx: 28 * scale, dy: 28 * scale)
    ctx.addEllipse(in: apertureRect)
    ctx.setLineWidth(3 * scale)
    ctx.setStrokeColor(NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.5).cgColor)
    ctx.strokePath()

    // Lens specular reflection
    let highlightRect = CGRect(x: camCenter.x - 45 * scale, y: camCenter.y + 15 * scale, width: 35 * scale, height: 22 * scale)
    ctx.addEllipse(in: highlightRect)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Squircle Inner Rim Highlight (macOS Specular Bevel) ---
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(2.5 * scale)
    let rimColors = [
        NSColor.white.withAlphaComponent(0.35).cgColor,
        NSColor.white.withAlphaComponent(0.05).cgColor
    ] as CFArray
    let rimGradient = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 1.0])!
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(rimGradient, start: CGPoint(x: size * 0.5, y: squircleRect.maxY), end: CGPoint(x: size * 0.5, y: squircleRect.minY), options: [])
    ctx.restoreGState()

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func generateAppIcon() {
    let scriptDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let iconsetDir = scriptDir.appendingPathComponent("Resources/AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconsetDir)
    try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    let master = drawBezelIcon(size: 1024)

    let iconSizes: [(String, CGFloat)] = [
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

    for (name, px) in iconSizes {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(px),
            pixelsHigh: Int(px),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = CGSize(width: px, height: px)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        master.draw(in: CGRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            let outURL = iconsetDir.appendingPathComponent(name)
            try? data.write(to: outURL)
        }
    }

    print("Generated iconset at \(iconsetDir.path)")
}

generateAppIcon()

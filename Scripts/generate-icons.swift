import AppKit
import Foundation
import CoreGraphics

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Background rounded square - ZJU-ish crimson gradient
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                            xRadius: size * 0.22, yRadius: size * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.78, green: 0.18, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.08, blue: 0.14, alpha: 1)
    ])!
    gradient.draw(in: path, angle: -90)

    // Soft highlight
    let hi = NSBezierPath(roundedRect: NSRect(x: size * 0.14, y: size * 0.55, width: size * 0.72, height: size * 0.28),
                          xRadius: size * 0.14, yRadius: size * 0.14)
    NSColor.white.withAlphaComponent(0.12).setFill()
    hi.fill()

    // Shield
    let s = size
    let shield = NSBezierPath()
    let top = s * 0.22
    let midY = s * 0.48
    let bottom = s * 0.82
    let left = s * 0.28
    let right = s * 0.72
    let cx = s * 0.5
    shield.move(to: NSPoint(x: cx, y: top))
    shield.curve(to: NSPoint(x: right, y: midY * 0.85),
                 controlPoint1: NSPoint(x: right - s * 0.02, y: top),
                 controlPoint2: NSPoint(x: right, y: top + s * 0.08))
    shield.curve(to: NSPoint(x: cx, y: bottom),
                 controlPoint1: NSPoint(x: right, y: s * 0.62),
                 controlPoint2: NSPoint(x: cx + s * 0.12, y: s * 0.74))
    shield.curve(to: NSPoint(x: left, y: midY * 0.85),
                 controlPoint1: NSPoint(x: cx - s * 0.12, y: s * 0.74),
                 controlPoint2: NSPoint(x: left, y: s * 0.62))
    shield.curve(to: NSPoint(x: cx, y: top),
                 controlPoint1: NSPoint(x: left, y: top + s * 0.08),
                 controlPoint2: NSPoint(x: left + s * 0.02, y: top))
    shield.close()

    NSColor.white.withAlphaComponent(0.95).setFill()
    shield.fill()

    // Inner check / link mark
    let check = NSBezierPath()
    check.lineWidth = max(2, s * 0.055)
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: NSPoint(x: s * 0.38, y: s * 0.50))
    check.line(to: NSPoint(x: s * 0.47, y: s * 0.60))
    check.line(to: NSPoint(x: s * 0.64, y: s * 0.40))
    NSColor(calibratedRed: 0.72, green: 0.12, blue: 0.18, alpha: 1).setStroke()
    check.stroke()

    // Small "Z" accent bottom
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.12, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9)
    ]
    let z = "Z" as NSString
    let zSize = z.size(withAttributes: attrs)
    z.draw(at: NSPoint(x: (s - zSize.width) / 2, y: s * 0.08), withAttributes: attrs)

    return image
}

func exportPNG(image: NSImage, path: String) {
    let pixelW = Int(image.size.width)
    let pixelH = Int(image.size.height)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelW,
        pixelsHigh: pixelH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Failed bitmap \(path)\n", stderr)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixelW, height: pixelH),
               from: .zero,
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let out = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed png \(path)\n", stderr)
        exit(1)
    }
    try! out.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path) (\(pixelW)x\(pixelH))")
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let outDir = (root as NSString).appendingPathComponent("OpenZweb/Resources/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] as [CGFloat] {
    let img = drawIcon(size: size)
    let path = (outDir as NSString).appendingPathComponent("icon_\(Int(size)).png")
    exportPNG(image: img, path: path)
}
print("Done. Icons in \(outDir)")

#!/usr/bin/env swift
// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [preview.png]
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon in a 1024x1024 space, origin bottom-left.
func drawIcon(_ ctx: CGContext) {
    // Apple's template: an 824pt squircle centered in the 1024pt canvas.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x2A1B77).setFill()
    body.fill()
    ctx.restoreGState()

    ctx.saveGState()
    body.addClip()
    NSGradient(colors: [color(0x241766), color(0x4B3BD0), color(0x7B66FF)])!.draw(in: body.bounds, angle: 62)
    NSGradient(starting: NSColor.white.withAlphaComponent(0.20), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 100, y: 480, width: 824, height: 444), angle: -90)

    let parent = CGPoint(x: 512, y: 650)
    let children: [(CGPoint, NSColor)] = [
        (CGPoint(x: 300, y: 340), color(0x4ADE80)), // running
        (CGPoint(x: 512, y: 300), color(0x60A5FA)), // finished
        (CGPoint(x: 724, y: 340), color(0xB4ADF2)), // waiting (opaque so the link does not show through)
    ]

    // Links from the session to each subagent.
    NSColor.white.withAlphaComponent(0.8).setStroke()
    for (point, _) in children {
        let link = NSBezierPath()
        link.lineWidth = 26
        link.lineCapStyle = .round
        link.move(to: CGPoint(x: parent.x, y: parent.y - 60))
        link.curve(
            to: point,
            controlPoint1: CGPoint(x: parent.x, y: parent.y - 190),
            controlPoint2: CGPoint(x: point.x, y: point.y + 190))
        link.stroke()
    }

    // Glow behind the running subagent.
    let glow = children[0]
    NSGradient(colors: [glow.1.withAlphaComponent(0.6), glow.1.withAlphaComponent(0)])!
        .draw(fromCenter: glow.0, radius: 0, toCenter: glow.0, radius: 150, options: [])

    for (point, tint) in children {
        let node = NSBezierPath(ovalIn: NSRect(x: point.x - 58, y: point.y - 58, width: 116, height: 116))
        tint.setFill()
        node.fill()
    }

    // The session: a white core with a soft halo.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: parent, radius: 0, toCenter: parent, radius: 170, options: [])
    let core = NSBezierPath(ovalIn: NSRect(x: parent.x - 92, y: parent.y - 92, width: 184, height: 184))
    NSColor.white.setFill()
    core.fill()
    let pupil = NSBezierPath(ovalIn: NSRect(x: parent.x - 38, y: parent.y - 38, width: 76, height: 76))
    color(0x4B3BD0).setFill()
    pupil.fill()
    ctx.restoreGState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try write(render(pixels: pixels), to: iconset.appendingPathComponent("\(name).png").path)
}

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let icns = resources.appendingPathComponent("AppIcon.icns")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }

if CommandLine.arguments.count > 1 { try write(render(pixels: 1024), to: CommandLine.arguments[1]) }
print("Wrote \(icns.path)")

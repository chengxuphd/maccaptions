// Draws the MacCaptions app icon at every size macOS needs and writes an .iconset folder.
// Usage: swift tools/make_icon.swift <output .iconset directory>
//        iconutil -c icns <that directory>      (tools/make_icon.sh does both)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2)
}
func fill(_ path: NSBezierPath, _ stops: [NSColor], angle: CGFloat = -90) {
    NSGradient(colors: stops, atLocations: stops.indices.map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) }, colorSpace: .sRGB)!
        .draw(in: path, angle: angle)
}
func shadowed(blur: CGFloat, dy: CGFloat, alpha: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(alpha); sh.shadowBlurRadius = blur; sh.shadowOffset = NSSize(width: 0, height: dy); sh.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Apple's grid: an 824 pt rounded square with a 100 pt margin on the 1024 canvas.
let bodyRect = NSRect(x: 100, y: 100, width: 824, height: 824)
func bodyPath() -> NSBezierPath { NSBezierPath(roundedRect: bodyRect, xRadius: 190, yRadius: 190) }

func drawBody(_ stops: [NSColor], glow: NSColor?, glowCenter: NSPoint = NSPoint(x: 380, y: 820)) {
    let body = bodyPath()
    shadowed(blur: 30, dy: -14, alpha: 0.32) { stops.last!.setFill(); body.fill() }
    fill(body, stops, angle: -55)
    NSGraphicsContext.saveGraphicsState(); body.addClip()
    if let glow {
        NSGradient(colors: [glow, glow.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
            .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 560, options: [])
    }
    // hairline inner edge, like the system icons have
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let edge = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 188, yRadius: 188); edge.lineWidth = 3; edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

/// The two subtitle lines: English (white) over Chinese (deep umber).
func subtitleLines(centerX: CGFloat, y: CGFloat, scale k: CGFloat = 1) {
    let h = 54 * k, w1 = 540 * k, w2 = 390 * k, gap = 36 * k
    shadowed(blur: 14, dy: -6, alpha: 0.30) {
        let a = pill(centerX - w1 / 2, y + h + gap, w1, h)
        fill(a, [color(0xFFFFFF), color(0xFFF0E0)])
        let b = pill(centerX - w2 / 2, y, w2, h)
        fill(b, [color(0x8F3A06), color(0x6A2600)])
    }
}

// MARK: designs

/// Sound becomes subtitles: a soft waveform above two subtitle lines (English white, Chinese deep umber), on warm orange.
func design1() {
    drawBody([color(0xFFB45C), color(0xFF8A1E), color(0xEE5A06)], glow: color(0xFFFFFF, 0.34))
    let heights: [CGFloat] = [80, 150, 240, 335, 415, 335, 240, 150, 80]
    let pitch: CGFloat = 60, w: CGFloat = 36, cy: CGFloat = 622
    let x0 = 512 - (CGFloat(heights.count - 1) * pitch) / 2 - w / 2
    for (i, h) in heights.enumerated() {
        let t = 1 - abs(CGFloat(i) - 4) / 4                         // 0 at the edges … 1 in the middle
        let p = pill(x0 + CGFloat(i) * pitch, cy - h / 2, w, h)
        fill(p, [color(0xFFFFFF, 0.62 + 0.38 * t), color(0xFFE0BC, 0.50 + 0.45 * t)])
    }
    subtitleLines(centerX: 512, y: 206)
}

func drawIcon(into ctx: NSGraphicsContext, scale s: CGFloat) {
    NSGraphicsContext.current = ctx
    let t = NSAffineTransform(); t.scaleX(by: s, yBy: s); t.concat()
    design1()
}

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    drawIcon(into: ctx, scale: CGFloat(pixels) / 1024)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let files: [(String, Int)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                              ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                              ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in files {
    if let data = png(pixels: px) { try? data.write(to: URL(fileURLWithPath: "\(out)/\(name).png")) }
}
print("wrote \(files.count) sizes to \(out)")

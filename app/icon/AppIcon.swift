// Renders the app icon. Usage: AppIcon <output.iconset> [logo.png]
// build.sh compiles and runs this, then packs the iconset with iconutil.
//
// Same language as the menu bar glyph: the Stream Deck Pedal seen from above —
// a dark slab with a narrow ▲ strip, a wide center pad (speed dots) and a
// narrow ▼ strip. The left strip is pressed and lit.

import AppKit

struct Palette {
    var backgroundTop: NSColor
    var backgroundBottom: NSColor
    var accent: NSColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

// Light "studio" tile so the black pedal reads like its product photo; teal is the only color.
let studio = Palette(backgroundTop: rgb(0xF6F7F9), backgroundBottom: rgb(0xCDD2DA), accent: rgb(0x2EE6C0))

// Device colors (the pedal is black rubber).
let surfaceTop = rgb(0x2C2F36)
let surfaceBottom = rgb(0x17191D)
let frontFace = rgb(0x0B0C0E)
let grooveColor = rgb(0x050506)
let markColor = rgb(0x6B7280)

/// Draws the icon into a `side`×`side` canvas (macOS grid: 824pt squircle in 1024).
func drawIcon(side: CGFloat, palette p: Palette) {
    let s = side / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle with drop shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor(white: 0, alpha: 0.35).cgColor)
    p.backgroundBottom.setFill()
    tilePath.fill()
    ctx.restoreGState()
    NSGradient(starting: p.backgroundTop, ending: p.backgroundBottom)!.draw(in: tilePath, angle: -90)

    ctx.saveGState()
    tilePath.addClip()

    // The slab: top face plus a front face below it for thickness.
    let top = NSRect(x: 182 * s, y: 330 * s, width: 660 * s, height: 470 * s)
    let thickness: CGFloat = 58 * s
    let radius: CGFloat = 92 * s
    let topPath = NSBezierPath(roundedRect: top, xRadius: radius, yRadius: radius)
    let body = NSBezierPath(roundedRect: NSRect(x: top.minX, y: top.minY - thickness, width: top.width, height: top.height),
                            xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26 * s), blur: 60 * s, color: NSColor(white: 0, alpha: 0.45).cgColor)
    frontFace.setFill()
    body.fill()
    ctx.restoreGState()
    NSGradient(starting: surfaceTop, ending: surfaceBottom)!.draw(in: topPath, angle: -90)

    // Zones and grooves.
    let sideW: CGFloat = 158 * s
    let groove: CGFloat = 16 * s
    let left = NSRect(x: top.minX, y: top.minY, width: sideW, height: top.height)
    let right = NSRect(x: top.maxX - sideW, y: top.minY, width: sideW, height: top.height)
    let center = NSRect(x: left.maxX + groove, y: top.minY, width: right.minX - left.maxX - groove * 2, height: top.height)

    ctx.saveGState()
    topPath.addClip()
    // Pressed left strip: lit from within.
    NSGradient(starting: p.accent.withAlphaComponent(0.30), ending: p.accent.withAlphaComponent(0.08))!
        .draw(in: left, angle: -90)
    grooveColor.setFill()
    NSRect(x: left.maxX, y: top.minY - thickness, width: groove, height: top.height + thickness).fill()
    NSRect(x: right.minX - groove, y: top.minY - thickness, width: groove, height: top.height + thickness).fill()
    // Soft top-edge highlight.
    NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 1, alpha: 0))!
        .draw(in: NSRect(x: top.minX, y: top.maxY - 60 * s, width: top.width, height: 60 * s), angle: -90)
    ctx.restoreGState()

    // Marks.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36 * s, color: p.accent.withAlphaComponent(0.9).cgColor)
    p.accent.set()
    chevron(in: left, up: true, s: s)
    ctx.restoreGState()

    markColor.set()
    chevron(in: right, up: false, s: s)
    dots(in: center, s: s)

    ctx.restoreGState()
}

func chevron(in r: NSRect, up: Bool, s: CGFloat) {
    let w: CGFloat = 78 * s
    let h: CGFloat = 42 * s
    let cy = r.midY
    let tip = up ? cy + h / 2 : cy - h / 2
    let base = up ? cy - h / 2 : cy + h / 2
    let path = NSBezierPath()
    path.move(to: NSPoint(x: r.midX - w / 2, y: base))
    path.line(to: NSPoint(x: r.midX, y: tip))
    path.line(to: NSPoint(x: r.midX + w / 2, y: base))
    path.lineWidth = 26 * s
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

func dots(in r: NSRect, s: CGFloat) {
    let d: CGFloat = 32 * s
    let spacing: CGFloat = 64 * s
    for i in -1...1 {
        let c = NSPoint(x: r.midX + CGFloat(i) * spacing, y: r.midY)
        NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
    }
}

func writePNG(side: Int, palette: Palette, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(side: CGFloat(side), palette: palette)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: AppIcon <output.iconset> [logo.png]\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
let palette = studio
if args.count >= 3 {
    writePNG(side: 512, palette: palette, to: URL(fileURLWithPath: args[2]))
}
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(side: base, palette: palette, to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(side: base * 2, palette: palette, to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

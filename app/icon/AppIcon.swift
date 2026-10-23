// Renders the app icon. Usage: AppIcon <output.iconset> [logo.png]
// build.sh compiles and runs this, then packs the iconset with iconutil.
//
// Same language as the menu bar glyph: the pedal's three plates, marked
// ▲ / speed dots / ▼, with the left plate pressed.

import AppKit

struct Palette {
    var backgroundTop: NSColor
    var backgroundBottom: NSColor
    var plateTop: NSColor
    var plateBottom: NSColor
    var plateEdge: NSColor
    var mark: NSColor
    var pressedTop: NSColor
    var pressedBottom: NSColor
    var pressedMark: NSColor
    var housing: NSColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let graphite = Palette(
    backgroundTop: rgb(0x3A3F4B), backgroundBottom: rgb(0x16181D),
    plateTop: rgb(0xFAFAFC), plateBottom: rgb(0xD9DCE3), plateEdge: rgb(0x9AA0AD),
    mark: rgb(0x2A2E37),
    pressedTop: rgb(0x5EF2D2), pressedBottom: rgb(0x16B89A), pressedMark: rgb(0x0B3D35),
    housing: rgb(0x2B2F38))

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

    // Plates: left (pressed), middle, right. Middle is a touch wider, like the hardware.
    let plateW: CGFloat = 176 * s
    let middleW: CGFloat = 196 * s
    let gap: CGFloat = 40 * s
    let plateH: CGFloat = 470 * s
    let baseY: CGFloat = 280 * s
    let totalW = plateW * 2 + middleW + gap * 2
    let x0 = (side - totalW) / 2
    let radius: CGFloat = 52 * s
    let press: CGFloat = 70 * s
    let depth: CGFloat = 26 * s

    let rects = [
        NSRect(x: x0, y: baseY, width: plateW, height: plateH - press),
        NSRect(x: x0 + plateW + gap, y: baseY, width: middleW, height: plateH),
        NSRect(x: x0 + plateW + gap + middleW + gap, y: baseY, width: plateW, height: plateH),
    ]

    // Housing the plates sit in.
    let housing = NSRect(x: x0 - 34 * s, y: baseY - 62 * s, width: totalW + 68 * s, height: 110 * s)
    p.housing.setFill()
    NSBezierPath(roundedRect: housing, xRadius: 46 * s, yRadius: 46 * s).fill()

    for (i, r) in rects.enumerated() {
        let pressed = i == 0
        // Side wall for depth (pressed plate sits lower, so less wall shows).
        let wall = r.offsetBy(dx: 0, dy: -(pressed ? depth * 0.4 : depth))
        (pressed ? p.pressedBottom.blended(withFraction: 0.35, of: .black)! : p.plateEdge).setFill()
        NSBezierPath(roundedRect: wall, xRadius: radius, yRadius: radius).fill()

        let face = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if pressed {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 60 * s, color: p.pressedTop.withAlphaComponent(0.55).cgColor)
            p.pressedBottom.setFill()
            face.fill()
            ctx.restoreGState()
            NSGradient(starting: p.pressedTop, ending: p.pressedBottom)!.draw(in: face, angle: -90)
        } else {
            NSGradient(starting: p.plateTop, ending: p.plateBottom)!.draw(in: face, angle: -90)
        }

        let markColor = pressed ? p.pressedMark : p.mark
        markColor.set()
        switch i {
        case 0: chevron(in: r, up: true, s: s)
        case 1: dots(in: r, s: s)
        default: chevron(in: r, up: false, s: s)
        }
    }
    ctx.restoreGState()
}

func chevron(in r: NSRect, up: Bool, s: CGFloat) {
    let w: CGFloat = 92 * s
    let h: CGFloat = 50 * s
    let cy = r.midY
    let tip = up ? cy + h / 2 : cy - h / 2
    let base = up ? cy - h / 2 : cy + h / 2
    let path = NSBezierPath()
    path.move(to: NSPoint(x: r.midX - w / 2, y: base))
    path.line(to: NSPoint(x: r.midX, y: tip))
    path.line(to: NSPoint(x: r.midX + w / 2, y: base))
    path.lineWidth = 30 * s
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

func dots(in r: NSRect, s: CGFloat) {
    let d: CGFloat = 34 * s
    let spacing: CGFloat = 70 * s
    for i in -1...1 {
        let c = NSPoint(x: r.midX, y: r.midY + CGFloat(i) * spacing)
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
let palette = graphite
if args.count >= 3 {
    writePNG(side: 512, palette: palette, to: URL(fileURLWithPath: args[2]))
}
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(side: base, palette: palette, to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(side: base * 2, palette: palette, to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

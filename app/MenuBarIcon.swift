// Menu bar glyph: the Stream Deck Pedal seen from above — one slab split into a
// narrow left strip (▲), a wide center pad (speed dots) and a narrow right strip (▼).
// Drawn in code as a template image so it follows the menu bar's appearance and
// can show live state.

import AppKit

struct MenuBarIconState: Equatable {
    enum Kind: Equatable {
        case active, notConnected, needsPermission
    }
    var kind: Kind = .active
    /// +1 left (up) held, -1 right (down) held, 0 neither.
    var direction: Int32 = 0
    var middleHeld = false
    /// 1...3 dots on the center pad.
    var speedLevel = 2
}

enum MenuBarIcon {
    static let size = NSSize(width: 24, height: 16)

    static func image(_ state: MenuBarIconState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    // Geometry, in points (bottom-left origin).
    private static let slab = NSRect(x: 1, y: 2, width: 22, height: 12)
    private static let slabRadius: CGFloat = 2.75
    private static let groove: CGFloat = 1
    private static let sideWidth: CGFloat = 6.25
    private static let left = NSRect(x: slab.minX, y: slab.minY, width: sideWidth, height: slab.height)
    private static let right = NSRect(x: slab.maxX - sideWidth, y: slab.minY, width: sideWidth, height: slab.height)
    private static let center = NSRect(x: left.maxX + groove, y: slab.minY,
                                       width: right.minX - left.maxX - groove * 2, height: slab.height)
    private static let lineWidth: CGFloat = 1.2
    /// Outline of a pressed zone; thinner so the mark has room inside.
    private static let pressedLineWidth: CGFloat = 1.0

    private static var slabPath: NSBezierPath {
        NSBezierPath(roundedRect: slab, xRadius: slabRadius, yRadius: slabRadius)
    }

    private static func draw(_ state: MenuBarIconState) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.set()

        if state.kind == .notConnected {
            // Hollow outline, no marks: nothing to drive.
            let outline = NSBezierPath(roundedRect: slab.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                       xRadius: slabRadius - lineWidth / 2, yRadius: slabRadius - lineWidth / 2)
            outline.lineWidth = lineWidth
            outline.stroke()
            for x in [left.maxX + groove / 2, right.minX - groove / 2] {
                NSRect(x: x - lineWidth / 2, y: slab.minY, width: lineWidth, height: slab.height).fill()
            }
            slash(ctx: ctx)
            return
        }

        // Solid slab with grooves and marks knocked out.
        slabPath.fill()
        clear(ctx) {
            NSRect(x: left.maxX, y: slab.minY, width: groove, height: slab.height).fill()
            NSRect(x: right.minX - groove, y: slab.minY, width: groove, height: slab.height).fill()
        }

        zone(left, pressed: state.direction == 1, ctx: ctx) { chevron(in: left, up: true) }
        zone(center, pressed: state.middleHeld, ctx: ctx) { dots(in: center, count: state.speedLevel) }
        zone(right, pressed: state.direction == -1, ctx: ctx) { chevron(in: right, up: false) }

        if state.kind == .needsPermission {
            badge(ctx: ctx)
        }
    }

    /// Idle: mark knocked out of the solid zone. Pressed: the zone "lights up" —
    /// hollowed to an outline with the mark drawn solid.
    private static func zone(_ rect: NSRect, pressed: Bool, ctx: CGContext, mark: () -> Void) {
        if pressed {
            ctx.saveGState()
            slabPath.addClip()
            clear(ctx) { rect.insetBy(dx: pressedLineWidth, dy: pressedLineWidth).fill() }
            ctx.restoreGState()
            mark()
        } else {
            clear(ctx, mark)
        }
    }

    private static func clear(_ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        body()
        ctx.restoreGState()
    }

    private static func chevron(in rect: NSRect, up: Bool) {
        let w: CGFloat = 2.6
        let h: CGFloat = 1.5
        let cy = rect.midY
        let tip = up ? cy + h / 2 : cy - h / 2
        let base = up ? cy - h / 2 : cy + h / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX - w / 2, y: base))
        path.line(to: NSPoint(x: rect.midX, y: tip))
        path.line(to: NSPoint(x: rect.midX + w / 2, y: base))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Speed: 1–3 dots in a row across the center pad.
    private static func dots(in rect: NSRect, count: Int) {
        let r: CGFloat = 0.8
        let spacing: CGFloat = 2.3
        let n = max(1, min(count, 3))
        let total = spacing * CGFloat(n - 1)
        for i in 0..<n {
            let x = rect.midX - total / 2 + spacing * CGFloat(i)
            NSBezierPath(ovalIn: NSRect(x: x - r, y: rect.midY - r, width: r * 2, height: r * 2)).fill()
        }
    }

    /// Diagonal strike-through with a knocked-out gap so it reads against the outline.
    private static func slash(ctx: CGContext) {
        let from = NSPoint(x: 2, y: 0.75)
        let to = NSPoint(x: 22, y: 15.25)
        clear(ctx) {
            let gap = NSBezierPath()
            gap.move(to: from)
            gap.line(to: to)
            gap.lineWidth = 3.4
            gap.stroke()
        }
        let line = NSBezierPath()
        line.move(to: from)
        line.line(to: to)
        line.lineWidth = 1.3
        line.lineCapStyle = .round
        line.stroke()
    }

    /// Filled "!" badge over the top-right corner.
    private static func badge(ctx: CGContext) {
        let c = NSPoint(x: 20.25, y: 12.25)
        let r: CGFloat = 3.75
        clear(ctx) {
            NSBezierPath(ovalIn: NSRect(x: c.x - r - 0.75, y: c.y - r - 0.75, width: (r + 0.75) * 2, height: (r + 0.75) * 2)).fill()
        }
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        clear(ctx) {
            NSBezierPath(roundedRect: NSRect(x: c.x - 0.5, y: c.y - 0.3, width: 1.0, height: 2.6), xRadius: 0.5, yRadius: 0.5).fill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 0.55, y: c.y - 2.1, width: 1.1, height: 1.1)).fill()
        }
    }
}

// Menu bar glyph: a front view of the pedal's three plates, each marked with its
// function (▲ up, speed dots, ▼ down). Drawn in code as a template image so it
// follows the menu bar's appearance and can show live state.

import AppKit

struct MenuBarIconState: Equatable {
    enum Kind: Equatable {
        case active, notConnected, needsPermission
    }
    var kind: Kind = .active
    /// +1 left (up) held, -1 right (down) held, 0 neither.
    var direction: Int32 = 0
    var middleHeld = false
    /// 1...3 dots on the middle plate.
    var speedLevel = 2
}

enum MenuBarIcon {
    static let size = NSSize(width: 22, height: 16)

    static func image(_ state: MenuBarIconState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        return image
    }

    // Plate geometry, in points (bottom-left origin).
    private static let plateY: CGFloat = 1.5
    private static let plateH: CGFloat = 13
    private static let left = NSRect(x: 1.5, y: plateY, width: 5.5, height: plateH)
    private static let middle = NSRect(x: 8.25, y: plateY, width: 5.5, height: plateH)
    private static let right = NSRect(x: 15, y: plateY, width: 5.5, height: plateH)
    private static let radius: CGFloat = 1.75
    private static let lineWidth: CGFloat = 1.25

    /// How far a held plate sinks, in points.
    private static let pressDepth: CGFloat = 2.5

    private static func draw(_ state: MenuBarIconState) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.set()

        if state.kind == .notConnected {
            // Hollow plates, no marks: nothing to drive.
            for rect in [left, middle, right] { outline(rect) }
            slash(ctx: ctx)
            return
        }

        plate(left, pressed: state.direction == 1, ctx: ctx) { chevron(in: $0, up: true) }
        plate(middle, pressed: state.middleHeld, ctx: ctx) { dots(in: $0, count: state.speedLevel) }
        plate(right, pressed: state.direction == -1, ctx: ctx) { chevron(in: $0, up: false) }

        if state.kind == .needsPermission {
            badge(ctx: ctx)
        }
    }

    /// Solid plate with its mark knocked out. A pressed plate sinks by `pressDepth`.
    private static func plate(_ rect: NSRect, pressed: Bool, ctx: CGContext, mark: (NSRect) -> Void) {
        var r = rect
        if pressed { r.size.height -= pressDepth }
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        mark(r)
        ctx.restoreGState()
    }

    private static func outline(_ rect: NSRect) {
        let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius - lineWidth / 2, yRadius: radius - lineWidth / 2)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func chevron(in rect: NSRect, up: Bool) {
        let w: CGFloat = 2.6
        let h: CGFloat = 1.5
        let cx = rect.midX
        let cy = rect.midY
        let tip = up ? cy + h / 2 : cy - h / 2
        let base = up ? cy - h / 2 : cy + h / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - w / 2, y: base))
        path.line(to: NSPoint(x: cx, y: tip))
        path.line(to: NSPoint(x: cx + w / 2, y: base))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func dots(in rect: NSRect, count: Int) {
        let r: CGFloat = 0.8
        let spacing: CGFloat = 2.5
        let n = max(1, min(count, 3))
        let total = spacing * CGFloat(n - 1)
        for i in 0..<n {
            let y = rect.midY - total / 2 + spacing * CGFloat(i)
            NSBezierPath(ovalIn: NSRect(x: rect.midX - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }
    }

    /// Diagonal strike-through with a knocked-out gap so it reads against the plates.
    private static func slash(ctx: CGContext) {
        let from = NSPoint(x: 2, y: 0.75)
        let to = NSPoint(x: 20, y: 15.25)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let gap = NSBezierPath()
        gap.move(to: from)
        gap.line(to: to)
        gap.lineWidth = 3.4
        gap.stroke()
        ctx.restoreGState()
        let line = NSBezierPath()
        line.move(to: from)
        line.line(to: to)
        line.lineWidth = 1.3
        line.lineCapStyle = .round
        line.stroke()
    }

    /// Filled "!" badge over the top-right corner.
    private static func badge(ctx: CGContext) {
        let center = NSPoint(x: 18.25, y: 12.25)
        let r: CGFloat = 3.75
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        NSBezierPath(ovalIn: NSRect(x: center.x - r - 0.75, y: center.y - r - 0.75, width: (r + 0.75) * 2, height: (r + 0.75) * 2)).fill()
        ctx.restoreGState()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        NSBezierPath(roundedRect: NSRect(x: center.x - 0.5, y: center.y - 0.3, width: 1.0, height: 2.6), xRadius: 0.5, yRadius: 0.5).fill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 0.55, y: center.y - 2.1, width: 1.1, height: 1.1)).fill()
        ctx.restoreGState()
    }
}

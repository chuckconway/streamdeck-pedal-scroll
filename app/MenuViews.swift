// Custom views hosted in the status menu: status header, live pedal map,
// permission callout and the scrolling speed preview.

import AppKit

/// Width shared by every custom menu view, so the menu doesn't jump in size.
let menuContentWidth: CGFloat = 300
private let inset: CGFloat = 14
private let accent = NSColor(srgbRed: 0x2E / 255, green: 0xE6 / 255, blue: 0xC0 / 255, alpha: 1)

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = false
    return field
}

/// Places a wrapping label at (x, y), as wide as the menu allows; returns its bottom edge.
private func place(_ field: NSTextField, x: CGFloat, y: CGFloat) -> CGFloat {
    let width = menuContentWidth - x - inset
    field.preferredMaxLayoutWidth = width
    let height = field.fittingSize.height
    field.frame = NSRect(x: x, y: y, width: width, height: height)
    return y + height
}

// MARK: - Status header

/// "Pedal Scroll", a colored dot with the status line, and an optional explanation.
final class StatusHeaderView: NSView {
    private let title = label("Pedal Scroll", size: 13, weight: .semibold)
    private let dot = NSView()
    private let headline = label("", size: 12)
    private let detail = label("", size: 11, color: .secondaryLabelColor)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: 50))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        [title, dot, headline, detail].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ copy: StatusCopy, dotColor: NSColor) {
        headline.stringValue = copy.headline
        detail.stringValue = copy.detail ?? ""
        detail.isHidden = copy.detail == nil
        dot.layer?.backgroundColor = dotColor.cgColor
        setAccessibilityLabel(([copy.headline] + [copy.detail].compactMap { $0 }).joined(separator: ". "))

        var bottom = place(title, x: inset, y: 6)
        bottom = place(headline, x: inset + 15, y: bottom + 3)
        dot.frame = NSRect(x: inset, y: headline.frame.midY - 4, width: 8, height: 8)
        if !detail.isHidden {
            bottom = place(detail, x: inset + 15, y: bottom + 2)
        }
        setFrameSize(NSSize(width: menuContentWidth, height: bottom + 8))
    }
}

// MARK: - Pedal map

/// The pedal from above with what each part does; the held part lights up.
final class PedalMapView: NSView {
    var state = PedalState() { didSet { needsDisplay = true } }
    var speedLevel = 2 { didSet { needsDisplay = true } }
    var connected = true { didSet { alphaValue = connected ? 1 : 0.4 } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: 88))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Pedal map: left pedal scrolls up, tap the middle pedal to change speed, right pedal scrolls down.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let slab = NSRect(x: inset, y: 2, width: menuContentWidth - inset * 2, height: 58)
        let path = NSBezierPath(roundedRect: slab, xRadius: 10, yRadius: 10)
        NSColor(white: 0.06, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0.32, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let sideW: CGFloat = 58
        let gap: CGFloat = 2
        let inner = slab.insetBy(dx: 1, dy: 1)
        let left = NSRect(x: inner.minX, y: inner.minY, width: sideW, height: inner.height)
        let right = NSRect(x: inner.maxX - sideW, y: inner.minY, width: sideW, height: inner.height)
        let center = NSRect(x: left.maxX + gap, y: inner.minY, width: right.minX - left.maxX - gap * 2, height: inner.height)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: 9, yRadius: 9).addClip()
        for (rect, lit) in [(left, state.left), (center, state.middle), (right, state.right)] {
            (lit ? accent.withAlphaComponent(0.25) : NSColor(white: 0.13, alpha: 1)).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let idle = NSColor(white: 0.56, alpha: 1)
        chevron(in: left, up: true, color: state.left ? accent : idle)
        chevron(in: right, up: false, color: state.right ? accent : idle)
        dots(in: center, count: speedLevel, color: state.middle ? accent : idle)

        let captionY = slab.maxY + 6
        let caption: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (text, rect) in [("Up", left), ("Tap: speed", center), ("Down", right)] {
            let string = NSAttributedString(string: text, attributes: caption)
            let size = string.size()
            string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: captionY))
        }
    }

    private func chevron(in rect: NSRect, up: Bool, color: NSColor) {
        let w: CGFloat = 12
        let h: CGFloat = 6
        // Flipped view: smaller y is higher on screen.
        let tip = up ? rect.midY - h / 2 : rect.midY + h / 2
        let base = up ? rect.midY + h / 2 : rect.midY - h / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX - w / 2, y: base))
        path.line(to: NSPoint(x: rect.midX, y: tip))
        path.line(to: NSPoint(x: rect.midX + w / 2, y: base))
        path.lineWidth = 2.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func dots(in rect: NSRect, count: Int, color: NSColor) {
        let d: CGFloat = 7
        let spacing: CGFloat = 14
        let n = max(1, min(count, 3))
        color.setFill()
        for i in 0..<n {
            let x = rect.midX + (CGFloat(i) - CGFloat(n - 1) / 2) * spacing
            NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
        }
    }
}

// MARK: - Permission callout

/// Explains a missing permission; the action is the menu item below it.
final class PermissionCalloutView: NSView {
    private let icon = NSImageView()
    private let title = label("", size: 13, weight: .semibold)
    private let body = label("", size: 12, color: .secondaryLabelColor)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: 50))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        [icon, title, body].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(title titleText: String, body bodyText: String) {
        title.stringValue = titleText
        body.stringValue = bodyText
        setAccessibilityLabel("\(titleText). \(bodyText)")
        let titleBottom = place(title, x: inset + 24, y: 4)
        let bottom = place(body, x: inset + 24, y: titleBottom + 2)
        icon.frame = NSRect(x: inset, y: 4, width: 16, height: 16)
        setFrameSize(NSSize(width: menuContentWidth, height: bottom + 4))
    }
}

// MARK: - Speed preview

/// Text scrolling at a speed's real rate (points per second, same units as the
/// scroll events), so the speeds can be compared before picking one.
final class SpeedPreviewView: NSView {
    var speedIndex = 1 { didSet { updateLabels() } }

    private let name = label("", size: 13, weight: .semibold)
    private let rate = label("", size: 11, color: .secondaryLabelColor)
    private let caption = label("Preview", size: 11, color: .secondaryLabelColor)
    private let text = PreviewTextView()
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuContentWidth, height: 98))
        let box = NSRect(x: inset, y: 2, width: menuContentWidth - inset * 2, height: 88)
        let background = NSView(frame: box)
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        addSubview(background)

        let column: CGFloat = 104
        caption.frame = NSRect(x: box.minX + 10, y: box.minY + 18, width: column - 16, height: 14)
        name.frame = NSRect(x: box.minX + 10, y: box.minY + 34, width: column - 16, height: 18)
        rate.frame = NSRect(x: box.minX + 10, y: box.minY + 54, width: column - 16, height: 14)
        text.frame = NSRect(x: box.minX + column, y: box.minY + 1, width: box.width - column - 1, height: box.height - 2)
        [caption, name, rate, text].forEach(addSubview)

        let divider = NSView(frame: NSRect(x: box.minX + column - 1, y: box.minY, width: 1, height: box.height))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(divider)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateLabels() {
        let speed = speeds[speedIndex]
        name.stringValue = speed.name
        rate.stringValue = speed.pageLabel
        text.pointsPerSecond = speed.pointsPerSecond
        setAccessibilityLabel("Speed preview: \(speed.name), \(speed.pageLabel)")
    }

    /// Animates only while the menu is open. `.common` mode keeps it running during menu tracking.
    func start() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        text.advance(by: now - lastTick)
        lastTick = now
    }
}

/// The scrolling lines inside the preview box.
private final class PreviewTextView: NSView {
    var pointsPerSecond: Double = 200
    private var offset: CGFloat = 0
    private let lineHeight: CGFloat = 14

    // Short lines so nothing wraps; '' is a paragraph break.
    private static let lines = [
        "Pedal Scroll keeps your",
        "hands free while you read.",
        "Press the left pedal to",
        "scroll up, the right one",
        "to scroll down. Let go",
        "and the page stops.",
        "",
        "Tap the middle pedal to",
        "change speed: slow for",
        "careful reading, medium",
        "for skimming, fast for",
        "racing through a long",
        "document or a log file.",
        "",
        "It works in any app that",
        "scrolls with a mouse",
        "wheel: browsers, PDFs,",
        "editors, sheet music.",
        "",
        "Happy reading.",
    ]

    override var isFlipped: Bool { true }

    func advance(by seconds: TimeInterval) {
        let period = lineHeight * CGFloat(Self.lines.count)
        offset = (offset + CGFloat(pointsPerSecond * seconds)).truncatingRemainder(dividingBy: period)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let period = lineHeight * CGFloat(Self.lines.count)
        // Draw two copies so the loop is seamless.
        for copy in 0..<2 {
            for (i, line) in Self.lines.enumerated() where !line.isEmpty {
                let y = CGFloat(i) * lineHeight + CGFloat(copy) * period - offset
                guard y > -lineHeight, y < bounds.height else { continue }
                NSAttributedString(string: line, attributes: attributes).draw(at: NSPoint(x: 10, y: y))
            }
        }
    }
}

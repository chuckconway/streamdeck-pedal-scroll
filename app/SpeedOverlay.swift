// A brief on-screen overlay (like the volume HUD) showing the new speed when the
// middle pedal is tapped. Drawn by the app itself, so it works with notifications
// off and the menu bar hidden. Never takes focus or clicks.

import AppKit

final class SpeedOverlay {
    private let panel: NSPanel
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var bars: [NSView] = []
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 200, height: 200)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true
        panel.contentView = background

        // The menu bar glyph, drawn large: center pad lit, dots = speed.
        glyph.frame = NSRect(x: 52, y: 92, width: 96, height: 64)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .white
        background.addSubview(glyph)

        name.frame = NSRect(x: 0, y: 52, width: Self.size.width, height: 26)
        name.alignment = .center
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.textColor = .white
        background.addSubview(name)

        for i in 0..<speeds.count {
            let bar = NSView(frame: NSRect(x: 44 + CGFloat(i) * 39, y: 32, width: 34, height: 6))
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 3
            background.addSubview(bar)
            bars.append(bar)
        }
    }

    func show(speedIndex: Int) {
        var state = MenuBarIconState()
        state.middleHeld = true
        state.speedLevel = speedIndex + 1
        let image = MenuBarIcon.image(state)
        image.size = glyph.frame.size
        glyph.image = image
        name.stringValue = speeds[speedIndex].name
        for (i, bar) in bars.enumerated() {
            bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(i <= speedIndex ? 1 : 0.22).cgColor
        }

        // Bottom center of the screen the pointer is on, like the system HUDs.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 120))
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Scroll speed \(speeds[speedIndex].name)", .priority: NSAccessibilityPriorityLevel.high.rawValue])

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        })
    }
}

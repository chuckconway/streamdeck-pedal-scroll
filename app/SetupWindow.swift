// First-run setup: a two-step checklist (permissions, pedal) that ticks itself
// off live. Opens at launch until finished once; "Setup Guide…" reopens it.

import AppKit

/// One checklist row: numbered badge, title and detail, and a trailing action or status.
private final class StepRow: NSView {
    private let badge = NSTextField(labelWithString: "")
    private let title: NSTextField
    private let detail: NSTextField
    private let status = NSTextField(labelWithString: "")
    let button: NSButton
    private let number: Int

    init(number: Int, title titleText: String, detail detailText: String, buttonTitle: String?) {
        self.number = number
        title = NSTextField(labelWithString: titleText)
        detail = NSTextField(wrappingLabelWithString: detailText)
        button = NSButton(title: buttonTitle ?? "", target: nil, action: nil)
        super.init(frame: .zero)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = false
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        button.bezelStyle = .rounded
        button.isHidden = buttonTitle == nil

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [badge, text, button, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `statusText` replaces the button when set (e.g. "Allowed", "Waiting for pedal…").
    func update(done: Bool, statusText: String?, statusColor: NSColor = .secondaryLabelColor,
                detail detailText: String? = nil, detailColor: NSColor = .secondaryLabelColor) {
        badge.stringValue = done ? "✓" : String(number)
        badge.textColor = done ? .black : .labelColor
        badge.layer?.backgroundColor = (done ? NSColor.systemGreen : NSColor.quaternaryLabelColor).cgColor
        if let detailText { detail.stringValue = detailText }
        detail.textColor = detailColor
        button.isHidden = done || statusText != nil || button.title.isEmpty
        status.isHidden = statusText == nil
        status.stringValue = statusText ?? ""
        status.textColor = statusColor
        badge.setAccessibilityLabel(done ? "Done" : "Step \(number)")
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window closes: whether setup was complete, and the login checkbox.
    var onClose: ((_ completed: Bool, _ startAtLogin: Bool) -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onGrantInputMonitoring: (() -> Void)?

    private let accessRow = StepRow(number: 1, title: "Allow Accessibility",
                                    detail: "Lets Pedal Scroll send scroll events to other apps.",
                                    buttonTitle: "Open Settings…")
    private let inputRow = StepRow(number: 2, title: "Allow Input Monitoring",
                                   detail: "macOS won't let Pedal Scroll read the pedal without it.",
                                   buttonTitle: "Open Settings…")
    private let pedalRow = StepRow(number: 2, title: "Connect your pedal",
                                   detail: "Plug the Elgato Stream Deck Pedal into a USB port.",
                                   buttonTitle: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start Pedal Scroll at login", target: nil, action: nil)
    private let doneButton = NSButton(title: "Finish Later", target: nil, action: nil)
    private var complete = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up Pedal Scroll"
        // The heading already says it; keep the title for the window list and VoiceOver only.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let heading = NSTextField(labelWithString: "Set up Pedal Scroll")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        let subheading = NSTextField(labelWithString: "Two steps, then your feet can scroll any app.")
        subheading.textColor = .secondaryLabelColor
        let headingText = NSStackView(views: [heading, subheading])
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 4
        let header = NSStackView(views: [icon, headingText])
        header.spacing = 14
        header.alignment = .centerY

        accessRow.button.target = self
        accessRow.button.action = #selector(grantAccessibility)
        inputRow.button.target = self
        inputRow.button.action = #selector(grantInputMonitoring)

        let steps = NSStackView(views: [accessRow, divider(), inputRow, divider(hiddenWith: inputRow), pedalRow])
        steps.orientation = .vertical
        steps.spacing = 0
        steps.wantsLayer = true
        steps.layer?.cornerRadius = 10
        steps.layer?.borderWidth = 1
        steps.layer?.borderColor = NSColor.separatorColor.cgColor
        for row in steps.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }

        let howTo = NSTextField(wrappingLabelWithString:
            "Left pedal scrolls up, right pedal scrolls down, tap the middle pedal to change speed.")
        howTo.textColor = .secondaryLabelColor
        howTo.font = .systemFont(ofSize: 12)
        howTo.isSelectable = false
        let compatibility = NSTextField(wrappingLabelWithString: "Works only with the Elgato Stream Deck Pedal.")
        compatibility.textColor = .secondaryLabelColor
        compatibility.font = .systemFont(ofSize: 12)
        compatibility.isSelectable = false

        loginCheckbox.state = .on
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(finish)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [loginCheckbox, spacer, doneButton])
        footer.alignment = .centerY

        let content = NSStackView(views: [header, steps, howTo, compatibility, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.setCustomSpacing(6, after: howTo)
        content.edgeInsets = NSEdgeInsets(top: 8, left: 32, bottom: 24, right: 32)
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = window!.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            steps.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -64),
            footer.widthAnchor.constraint(equalTo: steps.widthAnchor),
            howTo.widthAnchor.constraint(equalTo: steps.widthAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private var inputDivider: NSView?

    /// A hairline between steps; the one after Input Monitoring hides with that row.
    private func divider(hiddenWith row: NSView? = nil) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        if row != nil { inputDivider = line }
        return line
    }

    /// The login checkbox; set before `show()` so reopening reflects the current setting.
    var startAtLogin: Bool {
        get { loginCheckbox.state == .on }
        set { loginCheckbox.state = newValue ? .on : .off }
    }

    func show() {
        // Size the window to its content (rows grow when their text wraps).
        if let window, let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
        window?.center()
        // Menu bar apps aren't active by default; without this the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ state: SetupState, wrongDevice: Bool) {
        complete = state.isComplete
        accessRow.update(done: state.canPostEvents, statusText: state.canPostEvents ? "Allowed" : nil,
                         statusColor: .systemGreen)
        // Input Monitoring only appears when macOS actually refused access.
        inputRow.isHidden = !state.inputMonitoringDenied
        inputDivider?.isHidden = inputRow.isHidden
        inputRow.update(done: false, statusText: nil)
        if state.pedalConnected {
            pedalRow.update(done: true, statusText: "Connected", statusColor: .systemGreen,
                            detail: "Plug the Elgato Stream Deck Pedal into a USB port.")
        } else if wrongDevice {
            pedalRow.update(done: false, statusText: "Not supported", statusColor: .systemOrange,
                            detail: "That's a different Stream Deck. Pedal Scroll works only with the Elgato Stream Deck Pedal.",
                            detailColor: .systemOrange)
        } else {
            pedalRow.update(done: false, statusText: "Waiting for pedal…",
                            detail: "Plug the Elgato Stream Deck Pedal into a USB port.")
        }
        doneButton.title = complete ? "Done" : "Finish Later"
    }

    @objc private func grantAccessibility() { onGrantAccessibility?() }
    @objc private func grantInputMonitoring() { onGrantInputMonitoring?() }

    @objc private func finish() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?(complete, startAtLogin)
    }
}

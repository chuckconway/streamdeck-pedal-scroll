// Pedal Scroll — menu bar app.
// Reads Elgato Stream Deck Pedal HID directly and emits scroll-wheel events.

import Cocoa
import IOKit
import IOKit.hid
import CoreGraphics
import ServiceManagement
import os

let log = Logger(subsystem: "com.chuckconway.pedal-scroll", category: "hid")

// MARK: - Configuration (device IDs and speeds live in PedalLogic.swift)

let defaults = UserDefaults.standard
let kSpeedIndexKey = "speedIndex"
let kEnabledKey = "enabled"
let kShowOverlayKey = "showSpeedOverlay"
let kSetupCompletedKey = "setupCompleted"

// MARK: - Globals (main thread only)

var currentSpeedIndex: Int = {
    let stored = defaults.object(forKey: kSpeedIndexKey) as? Int ?? 1
    return max(0, min(stored, speeds.count - 1))
}()

var enabled: Bool = {
    if defaults.object(forKey: kEnabledKey) == nil { return true }
    return defaults.bool(forKey: kEnabledKey)
}()

var scrollTimer: DispatchSourceTimer?
var scrollDirection: Int32 = 0
let scrollQueue = DispatchQueue(label: "pedal.scroll.timer")

var pedalTracker = PedalTracker()

// Opened pedals and their report buffers (each device gets its own buffer).
var pedalBuffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
var pedalConnected: Bool { !pedalBuffers.isEmpty }
let hidReportBufferSize = 8

var hidManager: IOHIDManager?
/// HID open was refused by TCC (Input Monitoring).
var inputMonitoringDenied = false
/// Accessibility grant, required for CGEvent posting. Refreshed by `refreshPermissions()`.
var canPostEvents = CGPreflightPostEventAccess()
/// Registry IDs of plugged-in Elgato devices that aren't the Pedal (never opened).
var otherStreamDecks = Set<UInt64>()

// MARK: - Scroll engine

func scrollStart(direction: Int32) {
    guard enabled else { return }
    scrollStop()
    scrollDirection = direction
    let speed = speeds[currentSpeedIndex]
    // Captured by value: the handler runs on scrollQueue and must not read main-thread globals.
    let delta = speed.delta * direction
    let timer = DispatchSource.makeTimerSource(queue: scrollQueue)
    timer.schedule(deadline: .now(), repeating: speed.interval)
    timer.setEventHandler {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 1,
                                  wheel1: delta,
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
    scrollTimer = timer
    timer.resume()
}

func scrollStop() {
    scrollTimer?.cancel()
    scrollTimer = nil
    scrollDirection = 0
}

func cycleSpeed() {
    currentSpeedIndex = (currentSpeedIndex + 1) % speeds.count
    defaults.set(currentSpeedIndex, forKey: kSpeedIndexKey)
    if scrollTimer != nil {
        scrollStart(direction: scrollDirection)
    }
}

func setSpeed(index: Int) {
    guard speeds.indices.contains(index) else { return }
    currentSpeedIndex = index
    defaults.set(currentSpeedIndex, forKey: kSpeedIndexKey)
    if scrollTimer != nil {
        scrollStart(direction: scrollDirection)
    }
}

func setEnabled(_ value: Bool) {
    enabled = value
    defaults.set(enabled, forKey: kEnabledKey)
    // Re-enabling while a pedal is held resumes scrolling.
    applyScrollDirection(enabled ? pedalTracker.direction : 0)
}

/// Starts, stops, or reverses the scroll timer to match `direction`.
func applyScrollDirection(_ direction: Int32) {
    guard direction != scrollDirection else { return }
    if direction == 0 {
        scrollStop()
    } else {
        scrollStart(direction: direction)
    }
}

// MARK: - HID callbacks (run on the main run loop)

let inputReportCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, reportLength in
    let buf = UnsafeBufferPointer(start: report, count: reportLength)
    guard let state = PedalState(reportID: reportID, bytes: buf) else {
        log.debug("Ignored report id=\(reportID) length=\(reportLength)")
        return
    }
    log.debug("Pedals L=\(state.left) M=\(state.middle) R=\(state.right)")

    let previous = pedalTracker
    let middleTapped = pedalTracker.update(state)
    applyScrollDirection(pedalTracker.direction)

    if middleTapped {
        cycleSpeed()
        NotificationCenter.default.post(name: .pedalSpeedChanged, object: nil)
    } else if pedalTracker.state != previous.state {
        // Already on the main run loop; redraw the menu bar glyph immediately.
        NotificationCenter.default.post(name: .pedalInputChanged, object: nil)
    }
}

func hexCode(_ result: IOReturn) -> String {
    String(format: "0x%08x", result)
}

func postConnectionChanged() {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pedalConnectionChanged, object: nil)
    }
}

let deviceMatchingCallback: IOHIDDeviceCallback = { _, _, _, device in
    guard pedalBuffers[device] == nil else { return }
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
        log.error("IOHIDDeviceOpen failed: \(hexCode(openResult), privacy: .public)")
        if openResult == kIOReturnNotPermitted { inputMonitoringDenied = true }
        postConnectionChanged()
        return
    }
    log.info("Pedal opened")
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: hidReportBufferSize)
    buffer.initialize(repeating: 0, count: hidReportBufferSize)
    pedalBuffers[device] = buffer
    IOHIDDeviceRegisterInputReportCallback(device,
                                           buffer,
                                           hidReportBufferSize,
                                           inputReportCallback,
                                           nil)
    inputMonitoringDenied = false
    postConnectionChanged()
}

let deviceRemovalCallback: IOHIDDeviceCallback = { _, _, _, device in
    guard let buffer = pedalBuffers.removeValue(forKey: device) else { return }
    buffer.deallocate()
    // Pedal state is shared across devices, so any removal releases everything.
    scrollStop()
    pedalTracker.reset()
    postConnectionChanged()
}

func startHIDManager() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager

    let matching: [String: Any] = [
        kIOHIDVendorIDKey: PedalDevice.vendorID,
        kIOHIDProductIDKey: PedalDevice.productID,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchingCallback, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovalCallback, nil)
    // Common modes so the pedal keeps working while the status menu is open.
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if result != kIOReturnSuccess {
        log.error("IOHIDManagerOpen failed: \(hexCode(result), privacy: .public)")
        if result == kIOReturnNotPermitted { inputMonitoringDenied = true }
    }
}

/// Tears down and recreates the HID manager, e.g. after Input Monitoring is granted.
func restartHIDManager() {
    if let manager = hidManager {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    for buffer in pedalBuffers.values { buffer.deallocate() }
    pedalBuffers.removeAll()
    scrollStop()
    pedalTracker.reset()
    inputMonitoringDenied = false
    startHIDManager()
}

// MARK: - Other Stream Decks (only to explain "wrong device"; never opened)

var otherDeviceNotifyPort: IONotificationPortRef?
var otherDeviceAddedIterator: io_iterator_t = 0
var otherDeviceRemovedIterator: io_iterator_t = 0

/// Reads registry properties only, so it needs no permission and doesn't touch the device.
func drainOtherDevices(_ iterator: io_iterator_t, added: Bool) {
    var service = IOIteratorNext(iterator)
    while service != 0 {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        if added {
            let vendor = IORegistryEntryCreateCFProperty(service, kIOHIDVendorIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int ?? 0
            let product = IORegistryEntryCreateCFProperty(service, kIOHIDProductIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int ?? 0
            if PedalDevice.isOtherStreamDeck(vendorID: vendor, productID: product) {
                otherStreamDecks.insert(entryID)
            }
        } else {
            otherStreamDecks.remove(entryID)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

func startOtherDeviceWatch() {
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    otherDeviceNotifyPort = port
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

    func elgatoHIDDevices() -> CFDictionary {
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey] = PedalDevice.vendorID
        return matching
    }
    IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, elgatoHIDDevices(), { _, iterator in
        drainOtherDevices(iterator, added: true)
        postConnectionChanged()
    }, nil, &otherDeviceAddedIterator)
    IOServiceAddMatchingNotification(port, kIOTerminatedNotification, elgatoHIDDevices(), { _, iterator in
        drainOtherDevices(iterator, added: false)
        postConnectionChanged()
    }, nil, &otherDeviceRemovedIterator)
    // Draining arms the notifications and picks up devices already plugged in.
    drainOtherDevices(otherDeviceAddedIterator, added: true)
    drainOtherDevices(otherDeviceRemovedIterator, added: false)
}

/// Re-reads TCC grants. Returns true if anything changed.
@discardableResult
func refreshPermissions() -> Bool {
    var changed = false
    let post = CGPreflightPostEventAccess()
    if post != canPostEvents {
        canPostEvents = post
        changed = true
    }
    if inputMonitoringDenied && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
        restartHIDManager()
        changed = true
    }
    return changed
}

extension Notification.Name {
    static let pedalConnectionChanged = Notification.Name("pedalConnectionChanged")
    static let pedalSpeedChanged = Notification.Name("pedalSpeedChanged")
    static let pedalInputChanged = Notification.Name("pedalInputChanged")
}

let repositoryURL = URL(string: "https://github.com/chuckconway/streamdeck-pedal-scroll")!

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let header = StatusHeaderView()
    private let pedalMap = PedalMapView()
    private let callout = PermissionCalloutView()
    private let preview = SpeedPreviewView()
    private var calloutItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var permissionSeparator: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var speedItems: [NSMenuItem] = []
    /// Polls TCC while a permission is missing so the menu bar icon updates without a click.
    private var permissionPoll: Timer?
    private var overlayItem: NSMenuItem!
    private let overlay = SpeedOverlay()
    private var setup: SetupWindowController?

    /// On by default: with notifications off or the menu bar hidden, it's the only speed feedback.
    private var showOverlay: Bool {
        get { defaults.object(forKey: kShowOverlayKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kShowOverlayKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        startHIDManager()
        startOtherDeviceWatch()
        log.info("Launch: canPostEvents=\(canPostEvents, privacy: .public) inputMonitoringDenied=\(inputMonitoringDenied, privacy: .public)")
        if SetupState.showAtLaunch(completedBefore: defaults.bool(forKey: kSetupCompletedKey)) {
            // The setup window asks for Accessibility itself, one step at a time.
            showSetup()
        } else if !canPostEvents {
            // Shows the system Accessibility prompt once; later launches stay quiet.
            CGRequestPostEventAccess()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(speedCycled),
                                               name: .pedalSpeedChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAll),
                                               name: .pedalConnectionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateLive),
                                               name: .pedalInputChanged, object: nil)
        updateAll()
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(viewItem(header))
        menu.addItem(viewItem(pedalMap))

        permissionSeparator = .separator()
        menu.addItem(permissionSeparator)
        calloutItem = viewItem(callout)
        menu.addItem(calloutItem)
        permissionItem = actionItem("", #selector(grantPermission))
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        let speedHeader = NSMenuItem()
        speedHeader.attributedTitle = sectionTitle("Speed", note: "middle pedal cycles")
        speedHeader.isEnabled = false
        menu.addItem(speedHeader)
        menu.addItem(viewItem(preview))
        for (index, speed) in speeds.enumerated() {
            let item = actionItem(speed.name, #selector(selectSpeed(_:)))
            item.tag = index
            item.attributedTitle = speedTitle(speed)
            speedItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        pauseItem = actionItem("Pause Scrolling", #selector(togglePause))
        menu.addItem(pauseItem)
        loginItem = actionItem("Start at Login", #selector(toggleLogin))
        menu.addItem(loginItem)
        overlayItem = actionItem("Show Speed Overlay", #selector(toggleOverlay))
        menu.addItem(overlayItem)
        menu.addItem(.separator())

        menu.addItem(actionItem("Setup Guide…", #selector(showSetup)))
        menu.addItem(actionItem("About Pedal Scroll", #selector(showAbout)))
        menu.addItem(NSMenuItem(title: "Quit Pedal Scroll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func sectionTitle(_ title: String, note: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        result.append(NSAttributedString(string: " · \(note)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    /// "Medium            ~4.5 s per page", with the rate right-aligned and dimmed.
    private func speedTitle(_ speed: Speed) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: menuContentWidth - 40)]
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(string: speed.name, attributes: [
            .font: font, .paragraphStyle: paragraph,
        ])
        result.append(NSAttributedString(string: "\t\(speed.pageLabel)", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissions()
        updateAll()
        preview.speedIndex = currentSpeedIndex
        preview.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        preview.stop()
    }

    /// Hovering a speed previews it; anything else shows the selected speed.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let item, speedItems.contains(item) {
            preview.speedIndex = item.tag
        } else {
            preview.speedIndex = currentSpeedIndex
        }
    }

    private var currentStatus: AppStatus {
        AppStatus(inputMonitoringDenied: inputMonitoringDenied,
                  pedalConnected: pedalConnected,
                  otherStreamDeckConnected: !otherStreamDecks.isEmpty,
                  canPostEvents: canPostEvents,
                  enabled: enabled)
    }

    private static func dotColor(_ status: AppStatus) -> NSColor {
        switch status {
        case .needsInputMonitoring, .needsAccessibility: return .systemOrange
        case .notConnected, .wrongDevice: return .systemRed
        case .disabled: return .systemYellow
        case .active: return .systemGreen
        }
    }

    @objc private func updateAll() {
        // Accessibility is needed whether or not a pedal is plugged in, so explain it regardless.
        let missingPermission: (title: String, body: String, action: String)?
        if inputMonitoringDenied {
            missingPermission = ("Pedal Scroll needs Input Monitoring access",
                                 "macOS won't let apps read the pedal until you allow it.",
                                 "Open Input Monitoring Settings…")
        } else if !canPostEvents {
            missingPermission = ("Scrolling needs Accessibility access",
                                 "macOS blocks scroll events from apps until you allow them.",
                                 "Open Accessibility Settings…")
        } else {
            missingPermission = nil
        }
        if let missingPermission {
            callout.update(title: missingPermission.title, body: missingPermission.body)
            permissionItem.title = missingPermission.action
        }
        for item in [permissionSeparator, calloutItem, permissionItem] {
            item?.isHidden = missingPermission == nil
        }
        // Keep polling while the setup window is open so its steps tick off live.
        updatePermissionPoll(needed: missingPermission != nil || setup?.window?.isVisible == true)

        for (i, item) in speedItems.enumerated() {
            item.state = (i == currentSpeedIndex) ? .on : .off
        }
        pauseItem.state = enabled ? .off : .on
        overlayItem.state = showOverlay ? .on : .off
        setup?.update(setupState, wrongDevice: !pedalConnected && !otherStreamDecks.isEmpty)

        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.title = "Start at Login"
            loginItem.state = .on
        case .requiresApproval:
            loginItem.title = "Start at Login (approve in Settings…)"
            loginItem.state = .mixed
        default:
            loginItem.title = "Start at Login"
            loginItem.state = .off
        }

        updateLive()
    }

    /// Everything that follows the pedal in real time: header, pedal map, menu bar glyph.
    @objc private func updateLive() {
        let status = currentStatus
        let speedName = speeds[currentSpeedIndex].name
        let copy = StatusCopy(status, direction: pedalTracker.direction, speedName: speedName)
        header.update(copy, dotColor: Self.dotColor(status))
        pedalMap.state = pedalTracker.state
        pedalMap.speedLevel = currentSpeedIndex + 1
        pedalMap.connected = pedalConnected

        guard let button = statusItem.button else { return }
        var icon = MenuBarIconState()
        switch status {
        case .needsInputMonitoring, .needsAccessibility:
            icon.kind = .needsPermission
        case .notConnected, .wrongDevice:
            icon.kind = .notConnected
        case .disabled, .active:
            icon.kind = .active
        }
        icon.direction = pedalTracker.direction
        icon.middleHeld = pedalTracker.state.middle
        icon.speedLevel = currentSpeedIndex + 1

        button.image = MenuBarIcon.image(icon)
        button.image?.accessibilityDescription = "Pedal Scroll: \(copy.headline)"
        button.appearsDisabled = status == .disabled
        button.toolTip = "Pedal Scroll — \(copy.headline)"
    }

    private func updatePermissionPoll(needed: Bool) {
        if needed, permissionPoll == nil {
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                if refreshPermissions() { self?.updateAll() }
            }
        } else if !needed {
            permissionPoll?.invalidate()
            permissionPoll = nil
        }
    }

    @objc private func grantPermission() {
        if inputMonitoringDenied {
            grantInputMonitoring()
        } else if !canPostEvents {
            grantAccessibility()
        }
    }

    private func grantAccessibility() {
        // Prompts if undecided; otherwise the user has to flip the switch in Settings.
        if !CGRequestPostEventAccess() {
            openPrivacyPane("Privacy_Accessibility")
        }
        refreshPermissions()
        updateAll()
    }

    private func grantInputMonitoring() {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            openPrivacyPane("Privacy_ListenEvent")
        }
        refreshPermissions()
        updateAll()
    }

    private var setupState: SetupState {
        SetupState(canPostEvents: canPostEvents, inputMonitoringDenied: inputMonitoringDenied,
                   pedalConnected: pedalConnected)
    }

    @objc private func showSetup() {
        if setup == nil {
            let controller = SetupWindowController()
            controller.onGrantAccessibility = { [weak self] in self?.grantAccessibility() }
            controller.onGrantInputMonitoring = { [weak self] in self?.grantInputMonitoring() }
            controller.onClose = { [weak self] completed, startAtLogin in
                if completed { defaults.set(true, forKey: kSetupCompletedKey) }
                self?.setLoginItem(startAtLogin)
                self?.updateAll()
            }
            setup = controller
        }
        refreshPermissions()
        // First run defaults to on; afterwards mirror the real setting so closing never flips it.
        if defaults.bool(forKey: kSetupCompletedKey) {
            let status = SMAppService.mainApp.status
            setup?.startAtLogin = status == .enabled || status == .requiresApproval
        }
        setup?.update(setupState, wrongDevice: !pedalConnected && !otherStreamDecks.isEmpty)
        setup?.show()
        updateAll()
    }

    @objc private func speedCycled() {
        updateAll()
        if showOverlay { overlay.show(speedIndex: currentSpeedIndex) }
    }

    @objc private func toggleOverlay() {
        showOverlay.toggle()
        updateAll()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        setSpeed(index: sender.tag)
        updateAll()
    }

    @objc private func togglePause() {
        setEnabled(!enabled)
        updateAll()
    }

    @objc private func toggleLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            setLoginItem(false)
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        default:
            setLoginItem(true)
        }
        updateAll()
    }

    private func setLoginItem(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if !on, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            showError("Couldn't change Start at Login", detail: error.localizedDescription)
        }
    }

    private func showError(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func showAbout() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [
            .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(
            string: "Scroll any app with an Elgato Stream Deck Pedal.\n"
                + "Left scrolls up, right scrolls down, middle cycles speed.\n\n",
            attributes: plain)
        var link = plain
        link[.link] = repositoryURL
        credits.append(NSAttributedString(string: "github.com/chuckconway/streamdeck-pedal-scroll", attributes: link))
        var note = plain
        note[.foregroundColor] = NSColor.secondaryLabelColor
        credits.append(NSAttributedString(
            string: "\n\nFree and open source (MIT). Not affiliated with Elgato or Corsair.",
            attributes: note))

        // Menu bar apps aren't active by default; without this the panel opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

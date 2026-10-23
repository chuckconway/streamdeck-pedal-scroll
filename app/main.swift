// Pedal Scroll — menu bar app.
// Reads Elgato Stream Deck Pedal HID directly and emits scroll-wheel events.

import Cocoa
import IOKit
import IOKit.hid
import CoreGraphics
import ServiceManagement
import os

let log = Logger(subsystem: "com.chuckconway.pedal-scroll", category: "hid")

// MARK: - Configuration

let elgatoVendorID: Int = 0x0FD9
let pedalProductID: Int = 0x0086

struct Speed {
    let name: String
    let delta: Int32
    let interval: TimeInterval
}

let speeds: [Speed] = [
    Speed(name: "Slow",   delta: 2, interval: 0.020),
    Speed(name: "Medium", delta: 4, interval: 0.020),
    Speed(name: "Fast",   delta: 8, interval: 0.015),
]

let defaults = UserDefaults.standard
let kSpeedIndexKey = "speedIndex"
let kEnabledKey = "enabled"

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

    let middleTapped = pedalTracker.update(state)
    applyScrollDirection(pedalTracker.direction)

    if middleTapped {
        cycleSpeed()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pedalSpeedChanged, object: nil)
        }
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
        kIOHIDVendorIDKey: elgatoVendorID,
        kIOHIDProductIDKey: pedalProductID,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchingCallback, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovalCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if result != kIOReturnSuccess {
        log.error("IOHIDManagerOpen failed: \(hexCode(result), privacy: .public)")
        if result == kIOReturnNotPermitted { inputMonitoringDenied = true }
    }
}

/// Tears down and recreates the HID manager, e.g. after Input Monitoring is granted.
func restartHIDManager() {
    if let manager = hidManager {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    for buffer in pedalBuffers.values { buffer.deallocate() }
    pedalBuffers.removeAll()
    scrollStop()
    pedalTracker.reset()
    inputMonitoringDenied = false
    startHIDManager()
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
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var statusInfoItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var speedItems: [NSMenuItem] = []
    /// Polls TCC while a permission is missing so the menu bar icon updates without a click.
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        startHIDManager()
        log.info("Launch: canPostEvents=\(canPostEvents, privacy: .public) inputMonitoringDenied=\(inputMonitoringDenied, privacy: .public)")
        if !canPostEvents {
            // Shows the system Accessibility prompt once; later launches stay quiet.
            CGRequestPostEventAccess()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateAll),
                                               name: .pedalConnectionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAll),
                                               name: .pedalSpeedChanged, object: nil)
        updateAll()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self

        statusInfoItem = NSMenuItem(title: "Pedal: …", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)

        permissionItem = NSMenuItem(title: "", action: #selector(grantPermission), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        let speedHeader = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedHeader.isEnabled = false
        menu.addItem(speedHeader)
        for (index, speed) in speeds.enumerated() {
            let item = NSMenuItem(title: "  \(speed.name)", action: #selector(selectSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            speedItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Pedal Scroll", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Pedal Scroll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissions()
        updateAll()
    }

    private var currentStatus: AppStatus {
        AppStatus(inputMonitoringDenied: inputMonitoringDenied,
                  pedalConnected: pedalConnected,
                  canPostEvents: canPostEvents,
                  enabled: enabled)
    }

    @objc private func updateAll() {
        let status = currentStatus
        let dotColor: NSColor
        let statusText: String
        let symbol: String
        switch status {
        case .needsInputMonitoring:
            (dotColor, statusText, symbol) = (.systemOrange, "Needs Input Monitoring permission", "exclamationmark.triangle")
        case .notConnected:
            (dotColor, statusText, symbol) = (.systemRed, "Pedal not connected", "arrow.up.arrow.down.circle")
        case .needsAccessibility:
            (dotColor, statusText, symbol) = (.systemOrange, "Needs Accessibility permission", "exclamationmark.triangle")
        case .disabled:
            (dotColor, statusText, symbol) = (.systemYellow, "Pedal connected (disabled)", "arrow.up.arrow.down.square")
        case .active:
            (dotColor, statusText, symbol) = (.systemGreen, "Pedal connected", "arrow.up.arrow.down")
        }
        statusInfoItem.attributedTitle = makeStatusTitle(dot: dotColor, text: statusText)

        // Accessibility is needed whether or not a pedal is plugged in, so offer it regardless.
        if inputMonitoringDenied {
            permissionItem.title = "Grant Input Monitoring…"
            permissionItem.isHidden = false
        } else if !canPostEvents {
            permissionItem.title = "Grant Accessibility…"
            permissionItem.isHidden = false
        } else {
            permissionItem.isHidden = true
        }
        updatePermissionPoll(needed: !permissionItem.isHidden)

        for (i, item) in speedItems.enumerated() {
            item.state = (i == currentSpeedIndex) ? .on : .off
        }
        enabledItem.state = enabled ? .on : .off

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

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pedal Scroll: \(statusText)")
            button.image?.isTemplate = true
            button.toolTip = "Pedal Scroll — \(statusText)"
        }
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

    private func makeStatusTitle(dot color: NSColor, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        result.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        return result
    }

    @objc private func grantPermission() {
        if inputMonitoringDenied {
            // Prompts if undecided; otherwise the user has to flip the switch in Settings.
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
                openPrivacyPane("Privacy_ListenEvent")
            }
        } else if !canPostEvents {
            if !CGRequestPostEventAccess() {
                openPrivacyPane("Privacy_Accessibility")
            }
        }
        refreshPermissions()
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

    @objc private func toggleEnabled() {
        setEnabled(!enabled)
        updateAll()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            log.error("Login item toggle failed: \(error.localizedDescription, privacy: .public)")
            showError("Couldn't change Start at Login", detail: error.localizedDescription)
        }
        updateAll()
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
        let alert = NSAlert()
        alert.messageText = "Pedal Scroll"
        alert.informativeText = "Use your Elgato Stream Deck Pedal to scroll any application.\n\nLeft pedal scrolls up, right pedal scrolls down, middle pedal cycles speed.\n\nReads the pedal directly via USB HID — no Stream Deck app or Hammerspoon required."
        alert.runModal()
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

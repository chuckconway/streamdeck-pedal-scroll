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

var pedalConnected = false

// References that need to stay alive for the lifetime of the app
var hidManager: IOHIDManager!
var hidReportBuffer: UnsafeMutablePointer<UInt8>!
let hidReportBufferSize = 8

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

let deviceMatchingCallback: IOHIDDeviceCallback = { _, _, _, device in
    log.info("Pedal matched")
    IOHIDDeviceRegisterInputReportCallback(device,
                                           hidReportBuffer,
                                           hidReportBufferSize,
                                           inputReportCallback,
                                           nil)
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
        log.error("IOHIDDeviceOpen failed: \(String(format: "0x%08x", openResult), privacy: .public)")
    }
    pedalConnected = true
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pedalConnectionChanged, object: nil)
    }
}

let deviceRemovalCallback: IOHIDDeviceCallback = { _, _, _, _ in
    scrollStop()
    pedalTracker.reset()
    pedalConnected = false
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pedalConnectionChanged, object: nil)
    }
}

func startHIDManager() {
    hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: hidReportBufferSize)
    hidReportBuffer.initialize(repeating: 0, count: hidReportBufferSize)

    let matching: [String: Any] = [
        kIOHIDVendorIDKey: elgatoVendorID,
        kIOHIDProductIDKey: pedalProductID,
    ]
    IOHIDManagerSetDeviceMatching(hidManager, matching as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(hidManager, deviceMatchingCallback, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(hidManager, deviceRemovalCallback, nil)
    IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
    if result != kIOReturnSuccess {
        log.error("IOHIDManagerOpen failed: \(String(format: "0x%08x", result), privacy: .public)")
    }
}

extension Notification.Name {
    static let pedalConnectionChanged = Notification.Name("pedalConnectionChanged")
    static let pedalSpeedChanged = Notification.Name("pedalSpeedChanged")
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var statusInfoItem: NSMenuItem!
    private var speedItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        startHIDManager()
        NotificationCenter.default.addObserver(self, selector: #selector(updateAll),
                                               name: .pedalConnectionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAll),
                                               name: .pedalSpeedChanged, object: nil)
        updateAll()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()

        statusInfoItem = NSMenuItem(title: "Pedal: …", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)
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

    @objc private func updateAll() {
        let dotColor: NSColor
        let statusText: String
        if pedalConnected {
            if enabled {
                dotColor = .systemGreen
                statusText = "Pedal connected"
            } else {
                dotColor = .systemYellow
                statusText = "Pedal connected (disabled)"
            }
        } else {
            dotColor = .systemRed
            statusText = "Pedal not connected"
        }
        statusInfoItem.attributedTitle = makeStatusTitle(dot: dotColor, text: statusText)

        for (i, item) in speedItems.enumerated() {
            item.state = (i == currentSpeedIndex) ? .on : .off
        }
        enabledItem.state = enabled ? .on : .off
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        if let button = statusItem.button {
            let symbol: String
            if !pedalConnected {
                symbol = "arrow.up.arrow.down.circle"
            } else if !enabled {
                symbol = "arrow.up.arrow.down.square"
            } else {
                symbol = "arrow.up.arrow.down"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pedal Scroll")
            button.image?.isTemplate = true
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
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Pedal Scroll: failed to toggle login item: \(error)")
        }
        updateAll()
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

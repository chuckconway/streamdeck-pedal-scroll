// Pedal Scroll — menu bar app.
// Reads Elgato Stream Deck Pedal HID directly and emits scroll-wheel events.

import Cocoa
import IOKit
import IOKit.hid
import CoreGraphics
import ServiceManagement

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

// MARK: - Globals (mirrors the proven CLI structure exactly)

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

var lastLeftPressed = false
var lastMiddlePressed = false
var lastRightPressed = false

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
    let timer = DispatchSource.makeTimerSource(queue: scrollQueue)
    timer.schedule(deadline: .now(), repeating: speed.interval)
    timer.setEventHandler {
        let delta = speed.delta * scrollDirection
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
    if !enabled { scrollStop() }
}

// MARK: - HID callbacks (free functions, exactly like the CLI binary)

// Append-only debug log — surfaces what the app is actually doing.
let debugLogPath = "/tmp/pedalscroll-app.log"
func dbg(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: debugLogPath))
        }
    }
}

let inputReportCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, reportLength in
    dbg("HID callback: reportID=\(reportID) length=\(reportLength)")
    guard reportID == 0x01, reportLength >= 7 else {
        dbg("  rejected: reportID/length mismatch")
        return
    }
    let buf = UnsafeBufferPointer(start: report, count: reportLength)
    let bytes = (0..<reportLength).map { String(format: "%02x", buf[$0]) }.joined(separator: " ")
    dbg("  bytes: \(bytes)")
    let leftPressed   = buf[4] != 0
    let middlePressed = buf[5] != 0
    let rightPressed  = buf[6] != 0
    dbg("  L=\(leftPressed) M=\(middlePressed) R=\(rightPressed)")

    if leftPressed != lastLeftPressed {
        if leftPressed {
            scrollStart(direction: 1)
        } else if !rightPressed {
            scrollStop()
        }
        lastLeftPressed = leftPressed
    }

    if rightPressed != lastRightPressed {
        if rightPressed {
            scrollStart(direction: -1)
        } else if !leftPressed {
            scrollStop()
        }
        lastRightPressed = rightPressed
    }

    if middlePressed != lastMiddlePressed {
        if middlePressed {
            cycleSpeed()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pedalSpeedChanged, object: nil)
            }
        }
        lastMiddlePressed = middlePressed
    }
}

let deviceMatchingCallback: IOHIDDeviceCallback = { _, _, _, device in
    dbg("Device matched, registering callback and opening")
    IOHIDDeviceRegisterInputReportCallback(device,
                                           hidReportBuffer,
                                           hidReportBufferSize,
                                           inputReportCallback,
                                           nil)
    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    dbg("IOHIDDeviceOpen result: 0x\(String(format: "%08x", openResult))")
    if openResult != kIOReturnSuccess {
        NSLog("Pedal Scroll: IOHIDDeviceOpen failed: 0x%08x", openResult)
    }
    pedalConnected = true
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pedalConnectionChanged, object: nil)
    }
}

let deviceRemovalCallback: IOHIDDeviceCallback = { _, _, _, _ in
    scrollStop()
    lastLeftPressed = false
    lastMiddlePressed = false
    lastRightPressed = false
    pedalConnected = false
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .pedalConnectionChanged, object: nil)
    }
}

func startHIDManager() {
    dbg("=== App starting HID manager ===")
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
    dbg("IOHIDManagerOpen result: 0x\(String(format: "%08x", result))")
    if result != kIOReturnSuccess {
        NSLog("Pedal Scroll: IOHIDManagerOpen failed (0x%08x). Grant Input Monitoring permission.", result)
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

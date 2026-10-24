// Pure pedal logic — no IOKit, no AppKit — so it can be unit-tested.

import Foundation

/// The only device Pedal Scroll drives: the Elgato Stream Deck Pedal.
enum PedalDevice {
    static let vendorID = 0x0FD9   // Elgato
    static let productID = 0x0086  // Stream Deck Pedal

    /// Other Stream Deck models. Elgato also makes webcams, mics and capture cards
    /// (e.g. Cam Link 4K, 0x0066) under the same vendor ID, so "any other Elgato
    /// device" would be wrong. IDs as listed by python-elgato-streamdeck.
    static let otherStreamDeckProductIDs: Set<Int> = [
        0x0060, // Stream Deck (original)
        0x0063, // Stream Deck Mini
        0x006C, // Stream Deck XL
        0x006D, // Stream Deck (original, v2)
        0x0080, // Stream Deck MK.2
        0x0084, // Stream Deck +
        0x008F, // Stream Deck XL (v2)
        0x0090, // Stream Deck Mini (MK.2)
        0x009A, // Stream Deck Neo
    ]

    /// A Stream Deck that isn't the Pedal. Only used to explain why nothing
    /// happens; such devices are never opened.
    static func isOtherStreamDeck(vendorID: Int, productID: Int) -> Bool {
        vendorID == Self.vendorID && otherStreamDeckProductIDs.contains(productID)
    }
}

struct Speed {
    let name: String
    /// Points per scroll event.
    let delta: Int32
    /// Seconds between scroll events.
    let interval: TimeInterval

    /// A typical window's visible height, used to describe speeds in "pages".
    static let pageHeight: Double = 900

    var pointsPerSecond: Double { Double(delta) / interval }

    /// Seconds for content to cross a typical window.
    var secondsPerPage: Double { Self.pageHeight / pointsPerSecond }

    /// Plain-language rate: "~4.5 s per page".
    var pageLabel: String {
        let seconds = (secondsPerPage * 10).rounded() / 10
        let text = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        return "~\(text) s per page"
    }

    /// Rate for a preview `height` points tall. Motion looks faster in a small
    /// frame, so the real rate looks too fast in the menu's preview, while fully
    /// page-scaling it (a line crossing the box as slowly as a whole window) looks
    /// too slow. Scaling by the square root of the size ratio sits between the two
    /// and was picked by feel; relative speeds are unchanged.
    func previewPointsPerSecond(height: Double) -> Double {
        pointsPerSecond * (height / Self.pageHeight).squareRoot()
    }
}

let speeds: [Speed] = [
    Speed(name: "Slow",   delta: 2, interval: 0.020),
    Speed(name: "Medium", delta: 4, interval: 0.020),
    Speed(name: "Fast",   delta: 8, interval: 0.015),
]

struct PedalState: Equatable {
    var left = false
    var middle = false
    var right = false

    // Stream Deck Pedal input report: ID 0x01, button states at bytes 4/5/6.
    init?(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) {
        guard reportID == 0x01, bytes.count >= 7 else { return nil }
        left = bytes[4] != 0
        middle = bytes[5] != 0
        right = bytes[6] != 0
    }

    init(left: Bool = false, middle: Bool = false, right: Bool = false) {
        self.left = left
        self.middle = middle
        self.right = right
    }
}

/// Turns successive pedal states into a scroll direction and speed-cycle taps.
/// Left scrolls up (+1), right scrolls down (-1). When both are held, the most
/// recently pressed pedal wins; releasing it hands control back to the other.
struct PedalTracker {
    private(set) var state = PedalState()
    /// +1 up, -1 down, 0 stopped.
    private(set) var direction: Int32 = 0

    /// Returns true if the middle pedal was just pressed (cycle speed).
    mutating func update(_ new: PedalState) -> Bool {
        let leftDown = new.left && !state.left
        let rightDown = new.right && !state.right
        let middleDown = new.middle && !state.middle

        if leftDown && !rightDown {
            direction = 1
        } else if rightDown && !leftDown {
            direction = -1
        } else if leftDown && rightDown {
            direction = 1  // Simultaneous press: left wins, deterministically.
        }

        // The pedal driving the current direction was released (or never held).
        if direction == 1 && !new.left {
            direction = new.right ? -1 : 0
        } else if direction == -1 && !new.right {
            direction = new.left ? 1 : 0
        }

        state = new
        return middleDown
    }

    mutating func reset() {
        state = PedalState()
        direction = 0
    }
}

/// What the menu bar shows, highest-priority problem first.
enum AppStatus: Equatable {
    case needsInputMonitoring  // Can't read HID, so connection state is unknown.
    case wrongDevice           // No Pedal, but another Stream Deck is plugged in.
    case notConnected
    case needsAccessibility    // Pedal reads fine, but scroll events would be dropped.
    case disabled
    case active

    init(inputMonitoringDenied: Bool, pedalConnected: Bool, otherStreamDeckConnected: Bool = false,
         canPostEvents: Bool, enabled: Bool) {
        if inputMonitoringDenied {
            self = .needsInputMonitoring
        } else if !pedalConnected {
            self = otherStreamDeckConnected ? .wrongDevice : .notConnected
        } else if !canPostEvents {
            self = .needsAccessibility
        } else if !enabled {
            self = .disabled
        } else {
            self = .active
        }
    }
}

/// The menu's status line, plus an optional explanation under it.
struct StatusCopy: Equatable {
    var headline: String
    var detail: String?

    init(_ status: AppStatus, direction: Int32, speedName: String) {
        switch status {
        case .needsInputMonitoring:
            headline = "Needs Input Monitoring access"
        case .wrongDevice:
            headline = "Stream Deck Pedal not found"
            detail = "Found a Stream Deck, but Pedal Scroll works only with the Elgato Stream Deck Pedal."
        case .notConnected:
            headline = "No Stream Deck Pedal found"
            detail = "Plug in your Elgato Stream Deck Pedal."
        case .needsAccessibility:
            headline = "Needs Accessibility access"
        case .disabled:
            headline = "Paused"
        case .active:
            switch direction {
            case 1: headline = "Scrolling up · \(speedName)"
            case -1: headline = "Scrolling down · \(speedName)"
            default: headline = "Ready · \(speedName) speed"
            }
        }
    }
}

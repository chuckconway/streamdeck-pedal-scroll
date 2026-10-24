// Test runner for PedalLogic.swift. Run with ./test.sh (no Xcode required).

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

/// Feeds a sequence of (left, middle, right) states and returns directions after each.
func directions(_ steps: [(Bool, Bool, Bool)]) -> [Int32] {
    var tracker = PedalTracker()
    return steps.map { l, m, r in
        _ = tracker.update(PedalState(left: l, middle: m, right: r))
        return tracker.direction
    }
}

// Single pedal
check(directions([(true, false, false), (false, false, false)]) == [1, 0], "left hold/release")
check(directions([(false, false, true), (false, false, false)]) == [-1, 0], "right hold/release")

// Both held: last pressed wins, releasing it resumes the other
check(directions([(true, false, false), (true, false, true), (true, false, false), (false, false, false)]) == [1, -1, 1, 0],
      "left, +right, -right resumes up")
check(directions([(false, false, true), (true, false, true), (false, false, true), (false, false, false)]) == [-1, 1, -1, 0],
      "right, +left, -left resumes down")

// Releasing the older pedal while the newer is held keeps the newer direction
check(directions([(true, false, false), (true, false, true), (false, false, true)]) == [1, -1, -1],
      "left, +right, -left keeps down")

// Swap in a single report
check(directions([(true, false, false), (false, false, true)]) == [1, -1], "left -> right in one report")

// Simultaneous press is deterministic
check(directions([(true, false, true)]) == [1], "simultaneous press -> up")

// Middle pedal: edge-triggered, doesn't affect direction
do {
    var tracker = PedalTracker()
    check(tracker.update(PedalState(middle: true)) == true, "middle press cycles")
    check(tracker.update(PedalState(middle: true)) == false, "middle held does not re-cycle")
    check(tracker.update(PedalState(left: true, middle: true)) == false, "middle still held")
    check(tracker.direction == 1, "middle doesn't block scrolling")
    check(tracker.update(PedalState()) == false, "middle release does nothing")
    check(tracker.update(PedalState(middle: true)) == true, "second press cycles")
}

// Reset clears state so a held pedal re-triggers after reconnect
do {
    var tracker = PedalTracker()
    _ = tracker.update(PedalState(left: true))
    tracker.reset()
    check(tracker.direction == 0, "reset stops")
    _ = tracker.update(PedalState(left: true))
    check(tracker.direction == 1, "press after reset scrolls")
}

// Report parsing
func parse(_ id: UInt32, _ bytes: [UInt8]) -> PedalState? {
    bytes.withUnsafeBufferPointer { PedalState(reportID: id, bytes: $0) }
}
check(parse(1, [1, 0, 3, 0, 1, 0, 1, 0]) == PedalState(left: true, right: true), "parses L/R")
check(parse(1, [1, 0, 3, 0, 0, 1, 0]) == PedalState(middle: true), "parses M at min length")
check(parse(2, [1, 0, 3, 0, 1, 0, 1, 0]) == nil, "rejects other report IDs")
check(parse(1, [1, 0, 3, 0, 1, 0]) == nil, "rejects short reports")

// Status priority
func status(im: Bool = false, conn: Bool = true, post: Bool = true, on: Bool = true) -> AppStatus {
    AppStatus(inputMonitoringDenied: im, pedalConnected: conn, canPostEvents: post, enabled: on)
}
check(status() == .active, "all good -> active")
check(status(on: false) == .disabled, "disabled")
check(status(post: false, on: false) == .needsAccessibility, "accessibility outranks disabled")
check(status(conn: false, post: false) == .notConnected, "not connected outranks accessibility")
check(status(im: true, conn: false) == .needsInputMonitoring, "input monitoring outranks everything")

check(AppStatus(inputMonitoringDenied: false, pedalConnected: false, otherStreamDeckConnected: true,
                canPostEvents: true, enabled: true) == .wrongDevice, "other Stream Deck, no pedal -> wrongDevice")
check(AppStatus(inputMonitoringDenied: false, pedalConnected: true, otherStreamDeckConnected: true,
                canPostEvents: true, enabled: true) == .active, "pedal plus other Stream Deck -> active")

// Device filter
check(!PedalDevice.isOtherStreamDeck(vendorID: 0x0FD9, productID: 0x0086), "the Pedal is not 'other'")
check(PedalDevice.isOtherStreamDeck(vendorID: 0x0FD9, productID: 0x0080), "Stream Deck MK.2 is 'other'")
check(!PedalDevice.isOtherStreamDeck(vendorID: 0x05AC, productID: 0x0086), "non-Elgato devices are ignored")
check(!PedalDevice.isOtherStreamDeck(vendorID: 0x0FD9, productID: 0x0066), "Cam Link 4K is not a Stream Deck")

// Speeds
check(speeds.map(\.pointsPerSecond).map { Int($0.rounded()) } == [100, 200, 533], "real rates in pt/s")
check(speeds.map(\.pageLabel) == ["~9 s per page", "~4.5 s per page", "~1.7 s per page"], "page labels")
for speed in speeds {
    // Slower than the real rate (looked too fast), faster than page-scaled (looked too slow).
    let preview = speed.previewPointsPerSecond(height: 88)
    check(preview < speed.pointsPerSecond && preview > 88 / speed.secondsPerPage,
          "\(speed.name) preview between page-scaled and real rate")
}
check(abs(speeds[2].previewPointsPerSecond(height: 88) / speeds[0].previewPointsPerSecond(height: 88) - 5.33) < 0.01,
      "preview keeps relative speeds")

// Status copy
check(StatusCopy(.active, direction: 0, speedName: "Medium").headline == "Ready · Medium speed", "ready copy")
check(StatusCopy(.active, direction: 1, speedName: "Fast").headline == "Scrolling up · Fast", "scrolling up copy")
check(StatusCopy(.active, direction: -1, speedName: "Slow").headline == "Scrolling down · Slow", "scrolling down copy")
check(StatusCopy(.wrongDevice, direction: 0, speedName: "").detail?.contains("only with the Elgato Stream Deck Pedal") == true,
      "wrong device explains compatibility")
check(StatusCopy(.disabled, direction: 1, speedName: "Fast").headline == "Paused", "paused ignores direction")

// Setup
check(SetupState(canPostEvents: true, inputMonitoringDenied: false, pedalConnected: true).isComplete, "all steps done")
check(!SetupState(canPostEvents: false, inputMonitoringDenied: false, pedalConnected: true).isComplete, "needs accessibility")
check(!SetupState(canPostEvents: true, inputMonitoringDenied: true, pedalConnected: true).isComplete, "needs input monitoring")
check(!SetupState(canPostEvents: true, inputMonitoringDenied: false, pedalConnected: false).isComplete, "needs pedal")
check(SetupState.showAtLaunch(completedBefore: false) && !SetupState.showAtLaunch(completedBefore: true), "show until finished once")

if failures == 0 {
    print("All tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}

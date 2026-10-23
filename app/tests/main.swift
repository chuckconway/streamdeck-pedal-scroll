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

if failures == 0 {
    print("All tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}

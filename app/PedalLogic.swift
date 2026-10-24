// Pure pedal logic — no IOKit, no AppKit — so it can be unit-tested.

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

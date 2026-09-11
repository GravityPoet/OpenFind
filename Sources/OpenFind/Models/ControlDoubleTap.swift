import AppKit
import Carbon

/// Two clean press/release cycles. Other keys, clicks, overlapping modifiers,
/// and long holds invalidate the gesture; ordinary Control shortcuts pass on.
struct ControlDoubleTap {
    private var downAt: TimeInterval?
    private var downKey: UInt16?
    private var lastRelease: TimeInterval?
    private let maximumHold: TimeInterval = 0.3
    private let maximumGap: TimeInterval = 0.35

    mutating func reset() {
        downAt = nil
        downKey = nil
        lastRelease = nil
    }

    mutating func handle(_ event: NSEvent) -> Bool {
        guard event.type == .flagsChanged else { reset(); return false }
        return flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags, at: event.timestamp)
    }

    mutating func flagsChanged(
        keyCode: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval
    ) -> Bool {
        guard [UInt16(kVK_Control), UInt16(kVK_RightControl)].contains(keyCode) else {
            reset()
            return false
        }
        let flags = flags.intersection([.control, .option, .command, .shift, .function])
        if flags == .control {
            guard downAt == nil else { reset(); return false }
            if let lastRelease, time - lastRelease > maximumGap || time < lastRelease {
                self.lastRelease = nil
            }
            downAt = time
            downKey = keyCode
            return false
        }
        guard flags.isEmpty, let downAt, downKey == keyCode,
              time >= downAt, time - downAt <= maximumHold else { reset(); return false }
        self.downAt = nil
        downKey = nil
        if let lastRelease, downAt >= lastRelease, downAt - lastRelease <= maximumGap {
            self.lastRelease = nil
            return true
        }
        lastRelease = time
        return false
    }
}

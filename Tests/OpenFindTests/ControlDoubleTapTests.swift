import AppKit
import Carbon
import Testing
@testable import OpenFind

@MainActor
@Suite("Double Control Shortcut", .serialized)
struct ControlDoubleTapTests {
    @Test func twoCleanTapsTriggerExactlyOnceForEitherControlKey() {
        for code in [kVK_Control, kVK_RightControl] {
            var gesture = ControlDoubleTap()
            let gestureResult1 = gesture.flagsChanged(keyCode: UInt16(code), flags: .control, at: 0)
            #expect(!gestureResult1)
            let gestureResult2 = gesture.flagsChanged(keyCode: UInt16(code), flags: [], at: 0.05)
            #expect(!gestureResult2)
            let gestureResult3 = gesture.flagsChanged(keyCode: UInt16(code), flags: .control, at: 0.17)
            #expect(!gestureResult3)
            let gestureResult4 = gesture.flagsChanged(keyCode: UInt16(code), flags: [], at: 0.22)
            #expect(gestureResult4)
            let gestureResult5 = gesture.flagsChanged(keyCode: UInt16(code), flags: .control, at: 0.3)
            #expect(!gestureResult5)
            let gestureResult6 = gesture.flagsChanged(keyCode: UInt16(code), flags: [], at: 0.36)
            #expect(!gestureResult6)
        }
    }

    @Test func longHoldsAndSlowTapsDoNotTrigger() {
        var gesture = ControlDoubleTap()
        let gestureResult7 = gesture.flagsChanged(keyCode: 59, flags: .control, at: 0)
        #expect(!gestureResult7)
        let gestureResult8 = gesture.flagsChanged(keyCode: 59, flags: [], at: 0.6)
        #expect(!gestureResult8)
        let gestureResult9 = gesture.flagsChanged(keyCode: 59, flags: .control, at: 0.7)
        #expect(!gestureResult9)
        let gestureResult10 = gesture.flagsChanged(keyCode: 59, flags: [], at: 0.75)
        #expect(!gestureResult10)
        let gestureResult11 = gesture.flagsChanged(keyCode: 59, flags: .control, at: 1.4)
        #expect(!gestureResult11)
        let gestureResult12 = gesture.flagsChanged(keyCode: 59, flags: [], at: 1.45)
        #expect(!gestureResult12)
    }

    @Test func controlChordOtherModifiersAndOverlappingControlsCancelGesture() {
        var gesture = ControlDoubleTap()
        _ = gesture.flagsChanged(keyCode: 59, flags: .control, at: 0)
        _ = gesture.flagsChanged(keyCode: 59, flags: [], at: 0.05)
        let gestureResult13 = gesture.handle(keyEvent())
        #expect(!gestureResult13)
        _ = gesture.flagsChanged(keyCode: 59, flags: .control, at: 0.15)
        let gestureResult14 = gesture.flagsChanged(keyCode: 59, flags: [], at: 0.20)
        #expect(!gestureResult14)
        _ = gesture.flagsChanged(keyCode: 56, flags: .shift, at: 0.23)
        _ = gesture.flagsChanged(keyCode: 59, flags: .control, at: 0.3)
        let gestureResult15 = gesture.flagsChanged(keyCode: 59, flags: [], at: 0.35)
        #expect(!gestureResult15)
        _ = gesture.flagsChanged(keyCode: 59, flags: .control, at: 0.4)
        _ = gesture.flagsChanged(keyCode: 62, flags: .control, at: 0.45)
        let gestureResult16 = gesture.flagsChanged(keyCode: 62, flags: [], at: 0.5)
        #expect(!gestureResult16)
    }

    @Test func recordingDoubleControlKeepsComboRecordersBackwardCompatible() throws {
        let button = RecorderButton()
        var doubleTaps = 0
        var combinations = 0
        button.onDoubleControl = { doubleTaps += 1 }
        button.beginRecording { _ in combinations += 1 }
        for (flags, time) in [(NSEvent.ModifierFlags.control, 0.0), ([], 0.05), (.control, 0.15), ([], 0.20)] {
            button.flagsChanged(with: try #require(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: time,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 59
            )))
        }
        #expect(doubleTaps == 1 && combinations == 0)
        #expect(!button.isRecording)
        #expect(button.title == "⌃ ⌃")
        button.beginRecording { _ in combinations += 1 }
        button.keyDown(with: keyEvent())
        #expect(combinations == 1)
    }

    @Test func triggerPersistsAndPermissionStateNeverPretendsToBeRegistered() throws {
        let name = "OpenFindTests.DoubleControl.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = GlobalHotKeyController(defaults: defaults, accessibilityChecker: { false })
        controller.setTrigger(.doubleControl)
        #expect(controller.displayText == "⌃ ⌃")
        let reloaded = GlobalHotKeyController(defaults: defaults, accessibilityChecker: { false })
        defer { reloaded.stop() }
        #expect(reloaded.trigger == .doubleControl)
        reloaded.start {}
        #expect(reloaded.registrationState == .permissionRequired)
        reloaded.setEnabled(false)
        #expect(reloaded.registrationState == .disabled)
        reloaded.resetShortcut()
        #expect(reloaded.trigger == .shortcut && reloaded.shortcut == .defaultValue)
    }

    private func keyEvent() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0.1,
                        windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                        isARepeat: false, keyCode: UInt16(kVK_ANSI_C))!
    }
}

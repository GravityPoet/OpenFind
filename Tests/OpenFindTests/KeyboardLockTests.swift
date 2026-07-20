import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import OpenFind

@Suite("Keyboard Lock Tests")
struct KeyboardLockTests {
    @Test func gateSuppressesEveryKeyIncludingTheFormerUnlockShortcut() {
        let gate = KeyboardEventGate()
        let shortcut = KeyboardLockController.defaultShortcut
        gate.setEnabled(true)

        #expect(gate.shouldSuppress(keyCode: UInt16(kVK_ANSI_A), flags: []))
        #expect(gate.shouldSuppress(
            keyCode: UInt16(shortcut.keyCode),
            flags: [.maskCommand, .maskAlternate]
        ))
        #expect(gate.shouldSuppress(
            keyCode: UInt16(shortcut.keyCode),
            flags: [.maskCommand]
        ))
        #expect(gate.shouldSuppress(
            keyCode: UInt16(shortcut.keyCode),
            flags: [.maskCommand, .maskAlternate, .maskShift]
        ))
    }

    @Test func gateSuppressesMediaAndUnrelatedModifierEvents() {
        let gate = KeyboardEventGate()
        gate.setEnabled(true)

        #expect(gate.shouldSuppress(
            eventType: KeyboardEventGate.systemDefinedEventType,
            keyCode: 0,
            flags: []
        ))
        #expect(gate.shouldSuppress(
            eventType: .flagsChanged,
            keyCode: UInt16(kVK_Command),
            flags: [.maskCommand]
        ))
        #expect(gate.shouldSuppress(
            eventType: .flagsChanged,
            keyCode: UInt16(kVK_Option),
            flags: [.maskAlternate]
        ))
        #expect(gate.shouldSuppress(
            eventType: .flagsChanged,
            keyCode: UInt16(kVK_Shift),
            flags: [.maskShift]
        ))
    }

    @Test func disabledGatePassesAllEvents() {
        let gate = KeyboardEventGate()
        #expect(!gate.shouldSuppress(keyCode: UInt16(kVK_ANSI_A), flags: []))
    }

    @MainActor
    @Test func autoUnlockPreferencePersistsOnlySupportedValues() throws {
        let suite = "OpenFindTests.KeyboardLock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = KeyboardLockController(
            registry: GlobalHotKeyRegistry(),
            defaults: defaults
        )

        #expect(controller.autoUnlockMinutes == 5)
        controller.setAutoUnlockMinutes(30)
        #expect(KeyboardLockController(
            registry: GlobalHotKeyRegistry(),
            defaults: defaults
        ).autoUnlockMinutes == 30)
        controller.setAutoUnlockMinutes(7)
        #expect(controller.autoUnlockMinutes == 30)
    }

    @MainActor
    @Test func unlockShortcutPersistsAcrossControllerReload() throws {
        let suite = "OpenFindTests.KeyboardLockShortcut.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | optionKey),
            keyLabel: "L"
        )

        let controller = KeyboardLockController(
            registry: GlobalHotKeyRegistry(),
            defaults: defaults
        )
        #expect(controller.setShortcut(custom))
        #expect(controller.shortcut == custom)

        let reloaded = KeyboardLockController(
            registry: GlobalHotKeyRegistry(),
            defaults: defaults
        )
        #expect(reloaded.shortcut == custom)
    }
}

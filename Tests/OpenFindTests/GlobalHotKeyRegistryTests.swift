import AppKit
import Carbon
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Global Hot Key Registry Tests")
struct GlobalHotKeyRegistryTests {
    @Test func duplicateEnabledBindingsAreRejectedBeforeRegistration() {
        let registry = GlobalHotKeyRegistry()
        let shortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "G"
        )

        #expect(registry.bind(id: "first", shortcut: shortcut, enabled: true, action: {}) == .disabled)
        #expect(registry.bind(id: "second", shortcut: shortcut, enabled: true, action: {}) == .conflict)
        #expect(registry.state(for: "first") == .disabled)
        #expect(registry.state(for: "second") == .disabled)
    }

    @Test func disablingAReservedBindingReleasesItsLogicalConflict() {
        let registry = GlobalHotKeyRegistry()
        let shortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_G),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "G"
        )

        _ = registry.bind(id: "first", shortcut: shortcut, enabled: true, action: {})
        #expect(registry.bind(id: "first", shortcut: shortcut, enabled: false, action: {}) == .disabled)
        #expect(registry.bind(id: "second", shortcut: shortcut, enabled: true, action: {}) == .disabled)
    }

    @Test func externalConflictAutomaticallyRecoversAfterOwnerReleasesShortcut() async throws {
        let shortcut = GlobalShortcut(
            keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | shiftKey),
            keyLabel: "F19"
        )
        var blocker: EventHotKeyRef?
        let blockerID = EventHotKeyID(signature: 0x54455354, id: 1) // TEST
        let blockerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            blockerID,
            GetApplicationEventTarget(),
            0,
            &blocker
        )
        #expect(blockerStatus == noErr)
        defer {
            if let blocker { UnregisterEventHotKey(blocker) }
        }

        let registry = GlobalHotKeyRegistry(retryDelay: .milliseconds(20))
        _ = registry.bind(id: "recovering", shortcut: shortcut, enabled: true, action: {})
        registry.start()
        #expect(registry.state(for: "recovering") == .conflict)

        if let registeredBlocker = blocker {
            UnregisterEventHotKey(registeredBlocker)
            blocker = nil
        }
        for _ in 0..<100 where registry.state(for: "recovering") != .registered {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(registry.state(for: "recovering") == .registered)
        registry.stop()
    }
}

@MainActor
@Suite("Awake Hot Key Controller Tests")
struct AwakeHotKeyControllerTests {
    @Test func settingsPersistWhileRegistrationsRemainDisabledUntilStart() throws {
        let suite = "OpenFindTests.AwakeHotKeys.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = GlobalHotKeyRegistry()
        let sessions = AwakeSessionController(assertions: HotKeyFakeAssertions())
        let controller = AwakeHotKeyController(
            registry: registry,
            sessions: sessions,
            openMenu: {},
            defaults: defaults
        )
        let custom = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_Y),
            modifiers: UInt32(cmdKey | optionKey),
            keyLabel: "Y"
        )

        #expect(controller.setEnabled(true, for: .toggleSession))
        #expect(controller.setShortcut(custom, for: .toggleSession))
        #expect(controller.binding(for: .toggleSession)?.registrationState == .disabled)

        let reloaded = AwakeHotKeyController(
            registry: GlobalHotKeyRegistry(),
            sessions: sessions,
            openMenu: {},
            defaults: defaults
        )
        #expect(reloaded.binding(for: .toggleSession)?.isEnabled == true)
        #expect(reloaded.binding(for: .toggleSession)?.shortcut == custom)
    }

    @Test func openMenuActionInvokesPresenterWithoutStartingSession() {
        var presentationCount = 0
        let sessions = AwakeSessionController(assertions: HotKeyFakeAssertions())
        let controller = AwakeHotKeyController(
            registry: GlobalHotKeyRegistry(),
            sessions: sessions,
            openMenu: { presentationCount += 1 }
        )

        controller.perform(.openMenu)

        #expect(presentationCount == 1)
        #expect(!sessions.isActive)
        #expect(AwakeHotKeyAction.openMenu.defaultShortcut.keyLabel == "M")
    }
}

@MainActor
@Suite("Clipboard Hot Key Controller Tests")
struct ClipboardHotKeyControllerTests {
    @Test func shortcutPersistsWhileRegistrationIsStopped() throws {
        let suite = "OpenFindTests.ClipboardHotKeys.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.ClipboardHotKeys.\(UUID())"))
        )
        let controller = ClipboardController(
            registry: GlobalHotKeyRegistry(),
            store: store,
            defaults: defaults
        )
        let custom = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_H),
            modifiers: UInt32(cmdKey | optionKey),
            keyLabel: "H"
        )

        #expect(controller.setShortcut(custom))
        #expect(controller.shortcut == custom)

        let reloaded = ClipboardController(
            registry: GlobalHotKeyRegistry(),
            store: store,
            defaults: defaults
        )
        #expect(reloaded.shortcut == custom)
        #expect(reloaded.isShortcutEnabled)
    }
}

private final class HotKeyFakeAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

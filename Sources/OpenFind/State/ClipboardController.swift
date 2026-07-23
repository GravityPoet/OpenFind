import AppKit
import Carbon
import Foundation
import Observation

@MainActor
@Observable
final class ClipboardController {
    static let hotKeyID = "clipboardHistory"
    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "C"
    )
    private static let shortcutKeyCodeKey = "OpenFind.clipboardShortcut.keyCodeV1"
    private static let shortcutModifiersKey = "OpenFind.clipboardShortcut.modifiersV1"
    private static let shortcutLabelKey = "OpenFind.clipboardShortcut.labelV1"
    private static let shortcutEnabledKey = "OpenFind.clipboardShortcut.enabledV1"

    @ObservationIgnored private let registry: GlobalHotKeyRegistry
    let store: ClipboardHistoryStore
    private let monitor: ClipboardMonitor
    let snippetExpansion: ClipboardSnippetExpansionController
    let quickMerge: ClipboardQuickMergeController
    private let windowController: ClipboardHistoryWindowController
    @ObservationIgnored private let defaults: UserDefaults
    private var hasStarted = false
    private(set) var shortcut: GlobalShortcut
    private(set) var isShortcutEnabled: Bool
    private(set) var registrationState: GlobalHotKeyRegistry.State = .disabled

    init(
        registry: GlobalHotKeyRegistry,
        store: ClipboardHistoryStore = ClipboardHistoryStore(),
        defaults: UserDefaults = .standard
    ) {
        self.registry = registry
        self.store = store
        let windowController = ClipboardHistoryWindowController(store: store)
        self.windowController = windowController
        monitor = ClipboardMonitor(
            store: store,
            onExternalChange: { [weak windowController] in
                windowController?.cancelPasteStack()
            }
        )
        snippetExpansion = ClipboardSnippetExpansionController(store: store)
        quickMerge = ClipboardQuickMergeController(store: store)
        self.defaults = defaults
        shortcut = Self.loadShortcut(from: defaults)
        isShortcutEnabled = defaults.object(forKey: Self.shortcutEnabledKey) as? Bool ?? true
    }

    func start() {
        hasStarted = true
        monitor.start(interval: store.clipboardCheckInterval)
        snippetExpansion.refresh()
        quickMerge.refresh()
        registry.start()
        registrationState = registry.bind(
            id: Self.hotKeyID,
            shortcut: shortcut,
            enabled: isShortcutEnabled,
            action: { [weak self] in self?.handleShortcutInvocation() }
        )
        windowController.prepare()
    }

    func stop() {
        monitor.stop()
        snippetExpansion.stop()
        quickMerge.stop()
        windowController.cancelPasteStack()
        windowController.close()
        registry.unbind(id: Self.hotKeyID)
        hasStarted = false
        registrationState = .disabled
    }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        let state = registry.bind(
            id: Self.hotKeyID,
            shortcut: shortcut,
            enabled: isShortcutEnabled && hasStarted,
            action: { [weak self] in self?.handleShortcutInvocation() }
        )
        guard state != .conflict, !state.isFailure else {
            registrationState = state
            return false
        }
        self.shortcut = shortcut
        defaults.set(Int(shortcut.keyCode), forKey: Self.shortcutKeyCodeKey)
        defaults.set(Int(shortcut.modifiers), forKey: Self.shortcutModifiersKey)
        defaults.set(shortcut.keyLabel, forKey: Self.shortcutLabelKey)
        registrationState = hasStarted ? state : .disabled
        return true
    }

    func resetShortcut() {
        _ = setShortcut(Self.defaultShortcut)
    }

    func setShortcutEnabled(_ enabled: Bool) {
        isShortcutEnabled = enabled
        defaults.set(enabled, forKey: Self.shortcutEnabledKey)
        registrationState = registry.bind(
            id: Self.hotKeyID,
            shortcut: shortcut,
            enabled: enabled && hasStarted,
            action: { [weak self] in self?.handleShortcutInvocation() }
        )
    }

    func toggleWindow() {
        windowController.toggle()
    }

    func handleShortcutInvocation() {
        windowController.handleShortcutInvocation(shortcut: shortcut)
    }

    func showWindow() {
        windowController.show()
    }

    func setClipboardCheckInterval(_ interval: TimeInterval) {
        store.setClipboardCheckInterval(interval)
        if hasStarted {
            monitor.start(interval: store.clipboardCheckInterval)
        }
    }

    func setSnippetExpansionEnabled(_ enabled: Bool) {
        store.setSnippetExpansionEnabled(enabled)
        snippetExpansion.refresh()
    }

    func setQuickMergeEnabled(_ enabled: Bool) {
        store.setQuickMergeEnabled(enabled)
        quickMerge.refresh()
    }

    private static func loadShortcut(from defaults: UserDefaults) -> GlobalShortcut {
        guard let keyCode = UInt32(exactly: defaults.integer(forKey: shortcutKeyCodeKey)),
              let modifiers = UInt32(exactly: defaults.integer(forKey: shortcutModifiersKey)),
              let label = defaults.string(forKey: shortcutLabelKey) else {
            return defaultShortcut
        }
        let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
        return candidate.isValid ? candidate : defaultShortcut
    }
}

private extension GlobalHotKeyRegistry.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

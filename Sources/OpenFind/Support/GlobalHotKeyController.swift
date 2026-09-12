import Carbon
import Foundation
import Observation

@MainActor
@Observable
final class GlobalHotKeyController {
    enum RegistrationState: Equatable {
        case disabled
        case registered
        case conflict
        case failed(OSStatus)
        case permissionRequired
    }

    enum Trigger: String, CaseIterable {
        case shortcut
        case doubleControl
    }
    private static let triggerKey = "OpenFind.quickSearchTriggerV1"
    private static let enabledKey = "OpenFind.globalHotKeyEnabled"
    private static let keyCodeKey = "OpenFind.globalHotKeyKeyCode"
    private static let modifiersKey = "OpenFind.globalHotKeyModifiers"
    private static let keyLabelKey = "OpenFind.globalHotKeyLabel"
    private static let defaultMigrationKey = "OpenFind.globalHotKeyDefaultV2"
    private static let actionID = "toggleOpenFind"
    private let registry: GlobalHotKeyRegistry
    @ObservationIgnored private let doubleTap = ControlDoubleTapMonitor()
    @ObservationIgnored private let accessibilityChecker: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    private var hasStarted = false
    private var action: (@MainActor () -> Void)?

    private(set) var isEnabled: Bool
    private(set) var shortcut: GlobalShortcut
    private(set) var trigger: Trigger
    var displayText: String { trigger == .doubleControl ? "⌃ ⌃" : shortcut.displayText }
    private(set) var registrationState: RegistrationState = .disabled

    init(
        defaults: UserDefaults = .standard,
        registry: GlobalHotKeyRegistry = GlobalHotKeyRegistry(),
        accessibilityChecker: @escaping () -> Bool = { AccessibilityPermission.isTrusted }
    ) {
        self.defaults = defaults
        self.registry = registry
        self.accessibilityChecker = accessibilityChecker
        trigger = Trigger(rawValue: defaults.string(forKey: Self.triggerKey) ?? "") ?? .shortcut
        shortcut = Self.loadShortcut(from: defaults)
        if defaults.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledKey)
        }
    }

    func start(action: @escaping @MainActor () -> Void) {
        self.action = action
        hasStarted = true
        registry.start()
        refreshRegistration()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        refreshRegistration()
    }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        let state = registry.bind(
            id: Self.actionID,
            shortcut: shortcut,
            enabled: isEnabled,
            action: action ?? {}
        )
        guard state != .conflict, !isFailure(state) else { return false }
        self.shortcut = shortcut
        Self.saveShortcut(shortcut, to: defaults)
        trigger = .shortcut
        defaults.set(trigger.rawValue, forKey: Self.triggerKey)
        doubleTap.stop()
        registrationState = map(state)
        if !hasStarted { registrationState = .disabled }
        return true
    }

    func setTrigger(_ trigger: Trigger) {
        guard trigger != self.trigger else { return }
        self.trigger = trigger
        defaults.set(trigger.rawValue, forKey: Self.triggerKey)
        refreshRegistration()
    }

    func retryIfNeeded() {
        if trigger == .doubleControl { refreshRegistration() }
    }

    func resetShortcut() {
        _ = setShortcut(.defaultValue)
    }

    func stop() {
        doubleTap.stop()
        registry.unbind(id: Self.actionID)
        hasStarted = false
        action = nil
        registrationState = .disabled
    }

    func reloadPreferences() {
        let running = hasStarted
        let savedAction = action
        if running { stop() }
        shortcut = Self.loadShortcut(from: defaults)
        trigger = Trigger(rawValue: defaults.string(forKey: Self.triggerKey) ?? "") ?? .shortcut
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if running { start(action: savedAction ?? {}) }
    }

    private func refreshRegistration() {
        doubleTap.stop()
        guard hasStarted else {
            registrationState = .disabled
            return
        }
        if trigger == .doubleControl {
            registry.unbind(id: Self.actionID)
            guard isEnabled else { registrationState = .disabled; return }
            guard accessibilityChecker() else { registrationState = .permissionRequired; return }
            registrationState = doubleTap.start(action: { [weak self] in self?.action?() })
                ? .registered : .failed(OSStatus(eventInternalErr))
            return
        }
        let state = registry.bind(
            id: Self.actionID,
            shortcut: shortcut,
            enabled: isEnabled,
            action: action ?? {}
        )
        registrationState = map(state)
    }

    private func map(_ state: GlobalHotKeyRegistry.State) -> RegistrationState {
        switch state {
        case .disabled: return .disabled
        case .registered: return .registered
        case .conflict: return .conflict
        case let .failed(status): return .failed(status)
        }
    }

    private func isFailure(_ state: GlobalHotKeyRegistry.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func loadShortcut(from defaults: UserDefaults) -> GlobalShortcut {
        let storedShortcut: GlobalShortcut
        if defaults.object(forKey: keyCodeKey) != nil,
           defaults.object(forKey: modifiersKey) != nil,
           let label = defaults.string(forKey: keyLabelKey),
           let keyCode = UInt32(exactly: defaults.integer(forKey: keyCodeKey)),
           let modifiers = UInt32(exactly: defaults.integer(forKey: modifiersKey)) {
            let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
            storedShortcut = candidate.isValid ? candidate : .defaultValue
        } else {
            storedShortcut = .defaultValue
        }

        guard !defaults.bool(forKey: defaultMigrationKey) else { return storedShortcut }
        defaults.set(true, forKey: defaultMigrationKey)
        if storedShortcut == .legacyDefaultValue {
            saveShortcut(.defaultValue, to: defaults)
            return .defaultValue
        }
        return storedShortcut
    }

    private static func saveShortcut(_ shortcut: GlobalShortcut, to defaults: UserDefaults) {
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(Int(shortcut.modifiers), forKey: modifiersKey)
        defaults.set(shortcut.keyLabel, forKey: keyLabelKey)
    }
}

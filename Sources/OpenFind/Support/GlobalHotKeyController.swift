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
    }

    private static let enabledKey = "OpenFind.globalHotKeyEnabled"
    private static let keyCodeKey = "OpenFind.globalHotKeyKeyCode"
    private static let modifiersKey = "OpenFind.globalHotKeyModifiers"
    private static let keyLabelKey = "OpenFind.globalHotKeyLabel"
    private static let defaultMigrationKey = "OpenFind.globalHotKeyDefaultV2"
    private static let actionID = "toggleOpenFind"
    private let registry: GlobalHotKeyRegistry
    @ObservationIgnored private let defaults: UserDefaults
    private var hasStarted = false
    private var action: (@MainActor () -> Void)?

    private(set) var isEnabled: Bool
    private(set) var shortcut: GlobalShortcut
    private(set) var registrationState: RegistrationState = .disabled

    init(
        defaults: UserDefaults = .standard,
        registry: GlobalHotKeyRegistry = GlobalHotKeyRegistry()
    ) {
        self.defaults = defaults
        self.registry = registry
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
        let previous = self.shortcut
        let state = registry.bind(
            id: Self.actionID,
            shortcut: shortcut,
            enabled: isEnabled,
            action: action ?? {}
        )
        guard state != .conflict, !isFailure(state) else { return false }
        self.shortcut = shortcut
        Self.saveShortcut(shortcut, to: defaults)
        registrationState = map(state)
        if !hasStarted { registrationState = .disabled }
        _ = previous
        return true
    }

    func resetShortcut() {
        _ = setShortcut(.defaultValue)
    }

    func stop() {
        registry.unbind(id: Self.actionID)
        hasStarted = false
        action = nil
        registrationState = .disabled
    }

    private func refreshRegistration() {
        guard hasStarted else {
            registrationState = .disabled
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

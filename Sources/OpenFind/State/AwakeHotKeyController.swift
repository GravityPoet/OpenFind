import Carbon
import Foundation
import Observation

enum AwakeHotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case startSession
    case endSession
    case toggleSession
    case openMenu
    case toggleDisplaySleep
    case toggleScreenSaver
    case toggleClosedDisplaySleep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .startSession: L("Hotkey Start Awake Session")
        case .endSession: L("Hotkey End Awake Session")
        case .toggleSession: L("Hotkey Toggle Awake Session")
        case .openMenu: L("Hotkey Open Menu")
        case .toggleDisplaySleep: L("Hotkey Toggle Display Sleep")
        case .toggleScreenSaver: L("Hotkey Toggle Screen Saver")
        case .toggleClosedDisplaySleep: L("Hotkey Toggle Closed Display Sleep")
        }
    }

    var defaultShortcut: GlobalShortcut {
        let modifiers = UInt32(controlKey | optionKey)
        return switch self {
        case .startSession:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers, keyLabel: "S")
        case .endSession:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: modifiers, keyLabel: "E")
        case .toggleSession:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers, keyLabel: "A")
        case .openMenu:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers, keyLabel: "M")
        case .toggleDisplaySleep:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: modifiers, keyLabel: "D")
        case .toggleScreenSaver:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers, keyLabel: "R")
        case .toggleClosedDisplaySleep:
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: modifiers, keyLabel: "L")
        }
    }
}

struct AwakeHotKeyBinding: Identifiable, Equatable {
    let action: AwakeHotKeyAction
    var isEnabled: Bool
    var shortcut: GlobalShortcut
    var registrationState: GlobalHotKeyRegistry.State

    var id: String { action.id }
}

@MainActor
@Observable
final class AwakeHotKeyController {
    private static let prefix = "OpenFind.awakeHotKeyV1."
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registry: GlobalHotKeyRegistry
    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let preferences: AwakeSessionPreferences
    @ObservationIgnored private let openMenu: @MainActor () -> Void
    private(set) var bindings: [AwakeHotKeyBinding]
    private var hasStarted = false

    init(
        registry: GlobalHotKeyRegistry,
        sessions: AwakeSessionController,
        preferences: AwakeSessionPreferences = AwakeSessionPreferences(),
        openMenu: @escaping @MainActor () -> Void,
        defaults: UserDefaults = .standard
    ) {
        self.registry = registry
        self.sessions = sessions
        self.preferences = preferences
        self.openMenu = openMenu
        self.defaults = defaults
        bindings = AwakeHotKeyAction.allCases.map { action in
            Self.loadBinding(action: action, defaults: defaults)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        registry.start()
        for action in AwakeHotKeyAction.allCases { refresh(action) }
    }

    func stop() {
        for action in AwakeHotKeyAction.allCases {
            registry.unbind(id: registryID(for: action))
            updateBinding(action) { $0.registrationState = .disabled }
        }
        hasStarted = false
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for action: AwakeHotKeyAction) -> Bool {
        guard let binding = binding(for: action) else { return false }
        let state = registry.bind(
            id: registryID(for: action),
            shortcut: binding.shortcut,
            enabled: enabled && hasStarted,
            action: actionHandler(for: action)
        )
        guard state != .conflict, !state.isFailure else {
            updateBinding(action) { $0.registrationState = state }
            return false
        }
        updateBinding(action) {
            $0.isEnabled = enabled
            $0.registrationState = hasStarted ? state : .disabled
        }
        defaults.set(enabled, forKey: key("enabled", action: action))
        return true
    }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut, for action: AwakeHotKeyAction) -> Bool {
        guard shortcut.isValid, let binding = binding(for: action) else { return false }
        let state = registry.bind(
            id: registryID(for: action),
            shortcut: shortcut,
            enabled: binding.isEnabled && hasStarted,
            action: actionHandler(for: action)
        )
        guard state != .conflict, !state.isFailure else {
            updateBinding(action) { $0.registrationState = state }
            return false
        }
        updateBinding(action) {
            $0.shortcut = shortcut
            $0.registrationState = hasStarted ? state : .disabled
        }
        saveShortcut(shortcut, action: action)
        return true
    }

    func resetShortcut(for action: AwakeHotKeyAction) {
        _ = setShortcut(action.defaultShortcut, for: action)
    }

    func binding(for action: AwakeHotKeyAction) -> AwakeHotKeyBinding? {
        bindings.first { $0.action == action }
    }

    private func refresh(_ action: AwakeHotKeyAction) {
        guard let binding = binding(for: action) else { return }
        let state = registry.bind(
            id: registryID(for: action),
            shortcut: binding.shortcut,
            enabled: binding.isEnabled,
            action: actionHandler(for: action)
        )
        updateBinding(action) { $0.registrationState = state }
    }

    private func actionHandler(for action: AwakeHotKeyAction) -> @MainActor () -> Void {
        { [weak self] in self?.perform(action) }
    }

    func perform(_ action: AwakeHotKeyAction) {
        switch action {
        case .startSession:
            guard !sessions.isActive else { return }
            sessions.requestStart(preferences.defaultRequest())
        case .endSession:
            guard sessions.isActive else { return }
            sessions.requestEnd()
        case .toggleSession:
            if sessions.isActive {
                sessions.requestEnd()
            } else {
                sessions.requestStart(preferences.defaultRequest())
            }
        case .openMenu:
            openMenu()
        case .toggleDisplaySleep:
            guard let session = sessions.activeSession else { return }
            sessions.requestDisplaySleepAllowed(!session.options.allowsDisplaySleep)
        case .toggleScreenSaver:
            guard sessions.isActive else { return }
            sessions.requestScreenSaverAllowed(!sessions.allowsScreenSaver)
        case .toggleClosedDisplaySleep:
            guard sessions.isActive, sessions.closedDisplayModeSupported else { return }
            sessions.requestClosedDisplaySleepAllowed(!sessions.allowsClosedDisplaySleep)
        }
    }

    private func updateBinding(
        _ action: AwakeHotKeyAction,
        mutation: (inout AwakeHotKeyBinding) -> Void
    ) {
        guard let index = bindings.firstIndex(where: { $0.action == action }) else { return }
        mutation(&bindings[index])
    }

    private func registryID(for action: AwakeHotKeyAction) -> String {
        "awake.\(action.rawValue)"
    }

    private func key(_ component: String, action: AwakeHotKeyAction) -> String {
        Self.prefix + action.rawValue + "." + component
    }

    private func saveShortcut(_ shortcut: GlobalShortcut, action: AwakeHotKeyAction) {
        defaults.set(Int(shortcut.keyCode), forKey: key("keyCode", action: action))
        defaults.set(Int(shortcut.modifiers), forKey: key("modifiers", action: action))
        defaults.set(shortcut.keyLabel, forKey: key("label", action: action))
    }

    private static func loadBinding(
        action: AwakeHotKeyAction,
        defaults: UserDefaults
    ) -> AwakeHotKeyBinding {
        let base = prefix + action.rawValue + "."
        let shortcut: GlobalShortcut
        if defaults.object(forKey: base + "keyCode") != nil,
           defaults.object(forKey: base + "modifiers") != nil,
           let keyCode = UInt32(exactly: defaults.integer(forKey: base + "keyCode")),
           let modifiers = UInt32(exactly: defaults.integer(forKey: base + "modifiers")),
           let label = defaults.string(forKey: base + "label") {
            let stored = GlobalShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
            shortcut = stored.isValid ? stored : action.defaultShortcut
        } else {
            shortcut = action.defaultShortcut
        }
        return AwakeHotKeyBinding(
            action: action,
            isEnabled: defaults.bool(forKey: base + "enabled"),
            shortcut: shortcut,
            registrationState: .disabled
        )
    }
}

private extension GlobalHotKeyRegistry.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

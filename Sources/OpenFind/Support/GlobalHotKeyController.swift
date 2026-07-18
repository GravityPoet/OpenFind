import Carbon
import Foundation
import Observation

@MainActor
@Observable
final class GlobalHotKeyController {
    enum RegistrationState: Equatable {
        case disabled
        case registered
        case failed(OSStatus)
    }

    private static let enabledKey = "OpenFind.globalHotKeyEnabled"
    private static let keyCodeKey = "OpenFind.globalHotKeyKeyCode"
    private static let modifiersKey = "OpenFind.globalHotKeyModifiers"
    private static let keyLabelKey = "OpenFind.globalHotKeyLabel"
    private static let defaultMigrationKey = "OpenFind.globalHotKeyDefaultV2"
    private static let signature: OSType = 0x4F464E44 // OFND
    private static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var action: (@MainActor () -> Void)?
    private var hasStarted = false
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var isEnabled: Bool
    private(set) var shortcut: GlobalShortcut
    private(set) var registrationState: RegistrationState = .disabled

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        updateRegistration()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        updateRegistration()
    }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        self.shortcut = shortcut
        Self.saveShortcut(shortcut, to: defaults)
        updateRegistration()
        return true
    }

    func resetShortcut() {
        setShortcut(.defaultValue)
    }

    func stop() {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        hasStarted = false
        action = nil
    }

    fileprivate func handlePressedHotKey(_ identifier: EventHotKeyID) {
        guard identifier.signature == Self.signature,
              identifier.id == Self.identifier else { return }
        action?()
    }

    private func updateRegistration() {
        unregister()
        guard hasStarted, isEnabled else {
            registrationState = .disabled
            return
        }

        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                globalHotKeyEventHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
            guard status == noErr else {
                registrationState = .failed(status)
                return
            }
        }

        var registeredHotKey: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else {
            registrationState = .failed(status)
            return
        }

        hotKey = registeredHotKey
        registrationState = .registered
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> GlobalShortcut {
        let storedShortcut: GlobalShortcut
        if defaults.object(forKey: keyCodeKey) != nil,
           defaults.object(forKey: modifiersKey) != nil,
           let label = defaults.string(forKey: keyLabelKey),
           let keyCode = UInt32(exactly: defaults.integer(forKey: keyCodeKey)),
           let modifiers = UInt32(exactly: defaults.integer(forKey: modifiersKey)) {
            let candidate = GlobalShortcut(
                keyCode: keyCode,
                modifiers: modifiers,
                keyLabel: label
            )
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

private let globalHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        controller.handlePressedHotKey(identifier)
    }
    return noErr
}

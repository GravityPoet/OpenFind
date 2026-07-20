import Carbon
import Foundation
import Observation

@MainActor
@Observable
final class GlobalHotKeyRegistry {
    enum State: Equatable {
        case disabled
        case registered
        case conflict
        case failed(OSStatus)
    }

    private struct Entry {
        let shortcut: GlobalShortcut
        let enabled: Bool
        let action: @MainActor () -> Void
        let carbonID: UInt32
        var hotKey: EventHotKeyRef?
        var state: State
    }

    private static let signature: OSType = 0x4F464E44 // OFND
    private var eventHandler: EventHandlerRef?
    private var entries: [String: Entry] = [:]
    private var actionIDs: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 1
    private(set) var isStarted = false
    private(set) var installationStatus: OSStatus?

    func start() {
        guard !isStarted else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyRegistryEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        installationStatus = status
        guard status == noErr else {
            for id in entries.keys where entries[id]?.enabled == true {
                entries[id]?.state = .failed(status)
            }
            return
        }
        isStarted = true
        for id in entries.keys.sorted() {
            registerEntry(id: id)
        }
    }

    func stop() {
        for id in entries.keys { unregisterEntry(id: id) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        isStarted = false
        installationStatus = nil
    }

    @discardableResult
    func bind(
        id: String,
        shortcut: GlobalShortcut,
        enabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> State {
        guard shortcut.isValid else { return .failed(OSStatus(paramErr)) }
        if enabled, !isStarted, let installationStatus, installationStatus != noErr {
            return .failed(installationStatus)
        }
        if let existing = entries[id],
           existing.shortcut == shortcut,
           existing.enabled == enabled {
            entries[id]?.state = enabled && isStarted
                ? (existing.hotKey == nil ? registerEntry(id: id) : .registered)
                : .disabled
            return entries[id]?.state ?? .disabled
        }

        if enabled,
           entries.contains(where: { key, entry in
               key != id && entry.enabled && entry.shortcut == shortcut
           }) {
            return .conflict
        }

        let carbonID = entries[id]?.carbonID ?? allocateCarbonID()
        if let old = entries[id], old.hotKey != nil, isStarted {
            guard enabled else {
                UnregisterEventHotKey(old.hotKey)
                entries[id] = Entry(
                    shortcut: shortcut,
                    enabled: false,
                    action: action,
                    carbonID: carbonID,
                    hotKey: nil,
                    state: .disabled
                )
                actionIDs.removeValue(forKey: carbonID)
                return .disabled
            }
            // Register the replacement before releasing the old binding. If the
            // system rejects it, the old shortcut remains fully functional.
            let replacementID = allocateCarbonID()
            guard let replacement = register(shortcut: shortcut, carbonID: replacementID) else {
                return .failed(lastRegistrationStatus)
            }
            UnregisterEventHotKey(old.hotKey)
            actionIDs.removeValue(forKey: old.carbonID)
            entries[id] = Entry(
                shortcut: shortcut,
                enabled: enabled,
                action: action,
                carbonID: replacementID,
                hotKey: enabled ? replacement : nil,
                state: enabled ? .registered : .disabled
            )
            actionIDs[replacementID] = id
            return entries[id]?.state ?? .disabled
        }

        entries[id] = Entry(
            shortcut: shortcut,
            enabled: enabled,
            action: action,
            carbonID: carbonID,
            hotKey: nil,
            state: .disabled
        )
        if enabled && isStarted { return registerEntry(id: id) }
        return .disabled
    }

    func unbind(id: String) {
        unregisterEntry(id: id)
        entries.removeValue(forKey: id)
    }

    func state(for id: String) -> State {
        entries[id]?.state ?? .disabled
    }

    private var lastRegistrationStatus: OSStatus = noErr

    @discardableResult
    private func registerEntry(id: String) -> State {
        guard var entry = entries[id], entry.enabled else {
            entries[id]?.state = .disabled
            return .disabled
        }
        guard !entries.contains(where: { key, other in
            key != id && other.enabled && other.shortcut == entry.shortcut
        }) else {
            entry.state = .conflict
            entries[id] = entry
            return .conflict
        }
        guard let hotKey = register(shortcut: entry.shortcut, carbonID: entry.carbonID) else {
            entry.state = .failed(lastRegistrationStatus)
            entries[id] = entry
            return entry.state
        }
        entry.hotKey = hotKey
        entry.state = .registered
        entries[id] = entry
        actionIDs[entry.carbonID] = id
        return .registered
    }

    private func unregisterEntry(id: String) {
        guard let entry = entries[id] else { return }
        if let hotKey = entry.hotKey { UnregisterEventHotKey(hotKey) }
        actionIDs.removeValue(forKey: entry.carbonID)
        entries[id]?.hotKey = nil
        entries[id]?.state = .disabled
    }

    private func register(shortcut: GlobalShortcut, carbonID: UInt32) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: carbonID)
        lastRegistrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard lastRegistrationStatus == noErr else { return nil }
        return reference
    }

    private func allocateCarbonID() -> UInt32 {
        defer { nextCarbonID &+= 1 }
        return nextCarbonID
    }

    fileprivate func dispatch(carbonID: UInt32) {
        guard let id = actionIDs[carbonID] else { return }
        entries[id]?.action()
    }
}

private let globalHotKeyRegistryEventHandler: EventHandlerUPP = { _, event, userData in
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
    let registry = Unmanaged<GlobalHotKeyRegistry>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        registry.dispatch(carbonID: identifier.id)
    }
    return noErr
}

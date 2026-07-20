import ApplicationServices
import AppKit
import Carbon
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class KeyboardLockController {
    nonisolated static let hotKeyID = "keyboardLock"
    nonisolated static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(cmdKey | optionKey),
        keyLabel: "K"
    )

    enum State: Equatable {
        case disabled
        case arming(Int)
        case locked
        case permissionRequired
        case unavailable
    }

    private static let autoUnlockKey = "OpenFind.keyboardLockAutoUnlockMinutesV1"
    private static let shortcutKeyCodeKey = "OpenFind.keyboardLockShortcut.keyCodeV1"
    private static let shortcutModifiersKey = "OpenFind.keyboardLockShortcut.modifiersV1"
    private static let shortcutLabelKey = "OpenFind.keyboardLockShortcut.labelV1"
    @ObservationIgnored private let registry: GlobalHotKeyRegistry
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gate = KeyboardEventGate()
    @ObservationIgnored private let unlockPanel = KeyboardUnlockPanelController()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var armingTask: Task<Void, Never>?
    @ObservationIgnored private var autoUnlockTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleTokens: [NSObjectProtocol] = []
    private var hasStarted = false
    private(set) var state: State = .disabled
    private(set) var autoUnlockMinutes: Int
    private(set) var shortcut: GlobalShortcut
    private(set) var lastErrorMessage: String?
    private(set) var registrationState: GlobalHotKeyRegistry.State = .disabled

    init(registry: GlobalHotKeyRegistry, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.autoUnlockKey) as? Int ?? 5
        autoUnlockMinutes = [0, 5, 15, 30, 60].contains(stored) ? stored : 5
        shortcut = Self.loadShortcut(from: defaults)
    }

    var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    var isEngaged: Bool {
        if case .locked = state { return true }
        if case .arming = state { return true }
        return false
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        registry.start()
        registrationState = bindShortcut()
        observeLifecycle()
    }

    func stop() {
        hasStarted = false
        disable()
        removeLifecycleObservers()
        registry.unbind(id: Self.hotKeyID)
        registrationState = .disabled
    }

    func toggle() {
        if isEngaged { disable() } else { enable() }
    }

    func enable(countdownSeconds: Int = 3) {
        guard !isEngaged else { return }
        guard AccessibilityPermission.isTrusted else {
            state = .permissionRequired
            lastErrorMessage = KeyboardLockError.permissionRequired.localizedDescription
            return
        }

        let countdown = max(0, min(10, countdownSeconds))
        guard countdown > 0 else {
            activateLock()
            return
        }
        state = .arming(countdown)
        lastErrorMessage = nil
        armingTask = Task { @MainActor [weak self] in
            for remaining in stride(from: countdown, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self?.state = .arming(remaining)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.armingTask = nil
            self?.activateLock()
        }
    }

    private func activateLock() {
        guard AccessibilityPermission.isTrusted else {
            state = .permissionRequired
            lastErrorMessage = KeyboardLockError.permissionRequired.localizedDescription
            return
        }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << KeyboardEventGate.systemDefinedEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardLockEventCallback,
            userInfo: Unmanaged.passUnretained(gate).toOpaque()
        ) else {
            state = .unavailable
            lastErrorMessage = KeyboardLockError.tapUnavailable.localizedDescription
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        runLoopSource = source
        gate.setTap(tap)
        gate.setEnabled(true)
        CGEvent.tapEnable(tap: tap, enable: true)
        registry.unbind(id: Self.hotKeyID)
        registrationState = .disabled
        let lockedAt = Date()
        unlockPanel.show(lockedAt: lockedAt) { [weak self] in
            self?.disable()
        }
        state = .locked
        lastErrorMessage = nil
        scheduleAutoUnlock()
    }

    func disable() {
        let wasLocked = isLocked
        armingTask?.cancel()
        armingTask = nil
        autoUnlockTask?.cancel()
        autoUnlockTask = nil
        gate.setEnabled(false)
        gate.clearTap()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        unlockPanel.hide()
        if state != .disabled { state = .disabled }
        if wasLocked, hasStarted {
            registrationState = bindShortcut()
        }
    }

    func setAutoUnlockMinutes(_ minutes: Int) {
        guard [0, 5, 15, 30, 60].contains(minutes) else { return }
        autoUnlockMinutes = minutes
        defaults.set(minutes, forKey: Self.autoUnlockKey)
        if isLocked { scheduleAutoUnlock() }
    }

    @discardableResult
    func setShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        let state = registry.bind(
            id: Self.hotKeyID,
            shortcut: shortcut,
            enabled: hasStarted,
            action: { [weak self] in self?.toggle() }
        )
        if case .conflict = state {
            registrationState = state
            return false
        }
        if case .failed = state {
            registrationState = state
            return false
        }
        self.shortcut = shortcut
        defaults.set(Int(shortcut.keyCode), forKey: Self.shortcutKeyCodeKey)
        defaults.set(Int(shortcut.modifiers), forKey: Self.shortcutModifiersKey)
        defaults.set(shortcut.keyLabel, forKey: Self.shortcutLabelKey)
        if isLocked {
            registry.unbind(id: Self.hotKeyID)
            registrationState = .disabled
        } else {
            registrationState = state
        }
        return true
    }

    func resetShortcut() {
        _ = setShortcut(Self.defaultShortcut)
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func scheduleAutoUnlock() {
        autoUnlockTask?.cancel()
        autoUnlockTask = nil
        guard autoUnlockMinutes > 0 else { return }
        let delay = autoUnlockMinutes * 60
        autoUnlockTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.disable()
        }
    }

    private func observeLifecycle() {
        guard lifecycleTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ]
        lifecycleTokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.disable() }
            }
        }
    }

    private func bindShortcut() -> GlobalHotKeyRegistry.State {
        registry.bind(
            id: Self.hotKeyID,
            shortcut: shortcut,
            enabled: hasStarted,
            action: { [weak self] in self?.toggle() }
        )
    }

    private func removeLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        lifecycleTokens.forEach(center.removeObserver)
        lifecycleTokens.removeAll()
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

enum KeyboardLockError: Error, Equatable, LocalizedError {
    case permissionRequired
    case tapUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return L("Keyboard Cleaning Lock Accessibility Permission Required")
        case .tapUnavailable:
            return L("Keyboard Cleaning Lock Event Monitor Unavailable")
        }
    }
}

final class KeyboardEventGate: @unchecked Sendable {
    static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private let lock = NSLock()
    private var enabled = false
    private var tap: CFMachPort?

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }

    func setTap(_ tap: CFMachPort) {
        lock.withLock { self.tap = tap }
    }

    func clearTap() {
        lock.withLock { self.tap = nil }
    }

    func reenableTapIfNeeded() {
        lock.withLock {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    func shouldSuppress(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        shouldSuppress(eventType: .keyDown, keyCode: keyCode, flags: flags)
    }

    func shouldSuppress(
        eventType: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags
    ) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            _ = keyCode
            _ = flags
            return eventType == .keyDown
                || eventType == .keyUp
                || eventType == .flagsChanged
                || eventType == Self.systemDefinedEventType
        }
    }
}

private let keyboardLockEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let gate = Unmanaged<KeyboardEventGate>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        gate.reenableTapIfNeeded()
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown || type == .keyUp || type == .flagsChanged
        || type == KeyboardEventGate.systemDefinedEventType {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if gate.shouldSuppress(eventType: type, keyCode: keyCode, flags: event.flags) { return nil }
    }
    return Unmanaged.passUnretained(event)
}

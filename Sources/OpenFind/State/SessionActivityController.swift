import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import Observation

@MainActor
protocol SessionActivityPerforming: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func idleSeconds(useCursorMovement: Bool) -> TimeInterval
    func isScreenSaverActive() -> Bool
    func isScreenLocked() -> Bool
    func moveCursor(speed: CursorMovementSpeed)
    func lockScreen()
}

@MainActor
final class SystemSessionActivityPerformer: SessionActivityPerforming {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func idleSeconds(useCursorMovement: Bool) -> TimeInterval {
        let eventTypes: [CGEventType] = useCursorMovement
            ? [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            : [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? 0
    }

    func isScreenSaverActive() -> Bool {
        if isScreenLocked() { return true }
        return NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == "com.apple.ScreenSaver.Engine"
                || application.executableURL?.lastPathComponent == "ScreenSaverEngine"
        }
    }

    func isScreenLocked() -> Bool {
        guard let state = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (state["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    func moveCursor(speed: CursorMovementSpeed) {
        guard let event = CGEvent(source: nil) else { return }
        let current = event.location
        let step = speed.step
        let direction = Int(Date().timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : -1
        CGWarpMouseCursorPosition(
            CGPoint(x: current.x + CGFloat(direction) * step, y: current.y)
        )
    }

    func lockScreen() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        let keyCode = CGKeyCode(kVK_ANSI_Q)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        )
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

@MainActor
@Observable
final class SessionActivityController {
    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let preferences: AwakeSessionPreferences
    @ObservationIgnored private let performer: any SessionActivityPerforming
    @ObservationIgnored private let closedDisplayState: any ClosedDisplayStateMonitoring
    @ObservationIgnored private let tickInterval: TimeInterval
    @ObservationIgnored private var subscription: AwakeSessionEventSubscription?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var movementStartedAt: Date?
    private var lastMovementAt: Date?
    private var didLockCurrentSession = false
    private var displaySleepBeforeLock: Bool?
    private(set) var lastErrorMessage: String?

    init(
        sessions: AwakeSessionController,
        preferences: AwakeSessionPreferences,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        performer: any SessionActivityPerforming = SystemSessionActivityPerformer(),
        closedDisplayState: (any ClosedDisplayStateMonitoring)? = nil,
        tickInterval: TimeInterval = 1
    ) {
        self.sessions = sessions
        self.preferences = preferences
        self.performer = performer
        self.closedDisplayState = closedDisplayState ?? SystemClosedDisplayStateMonitor(
            workspaceCenter: workspaceCenter
        )
        self.tickInterval = min(5, max(0.05, tickInterval))
    }

    func start() {
        guard subscription == nil else { return }
        subscription = sessions.observeEvents { [weak self] event in
            self?.handle(event)
        }
        closedDisplayState.start { [weak self] state in
            self?.handleClosedDisplayState(state)
        }
        if let session = sessions.activeSession { begin(session) }
    }

    func stop() {
        if let session = sessions.activeSession, displaySleepBeforeLock != nil {
            reconcileDisplaySleepForLockedScreen(session: session, isLocked: false)
        }
        subscription?.cancel()
        subscription = nil
        closedDisplayState.stop()
        tickTask?.cancel()
        tickTask = nil
        activeSessionID = nil
        movementStartedAt = nil
        lastMovementAt = nil
        didLockCurrentSession = false
        displaySleepBeforeLock = nil
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func handle(_ event: AwakeSessionEvent) {
        switch event {
        case let .started(session): begin(session)
        case let .replaced(_, current): begin(current)
        case let .updated(session):
            guard activeSessionID == session.id else { begin(session); return }
        case .ended:
            tickTask?.cancel()
            tickTask = nil
            activeSessionID = nil
            movementStartedAt = nil
            lastMovementAt = nil
            didLockCurrentSession = false
            displaySleepBeforeLock = nil
        }
    }

    private func begin(_ session: AwakeSession) {
        activeSessionID = session.id
        movementStartedAt = nil
        lastMovementAt = nil
        didLockCurrentSession = false
        displaySleepBeforeLock = nil
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.tick()
                do {
                    try await Task.sleep(for: .seconds(self.tickInterval))
                } catch {
                    return
                }
            }
        }
    }

    private func tick() {
        guard let session = sessions.activeSession,
              session.id == activeSessionID else { return }
        let now = Date()
        let cursorIdle = performer.idleSeconds(useCursorMovement: true)
        let lockIdle = performer.idleSeconds(
            useCursorMovement: preferences.lockUsesCursorMovement
        )
        let isScreenLocked = performer.isScreenLocked()
        reconcileDisplaySleepForLockedScreen(session: session, isLocked: isScreenLocked)
        if didLockCurrentSession,
           !isScreenLocked,
           lockIdle < Double(preferences.screenLockInactivityThresholdSeconds) {
            didLockCurrentSession = false
        }

        if cursorIdle < Double(preferences.cursorInactivityThresholdSeconds) {
            movementStartedAt = nil
            lastMovementAt = nil
        }

        if preferences.cursorMovementEnabled,
           !performer.isScreenSaverActive(),
           cursorIdle >= Double(preferences.cursorInactivityThresholdSeconds) {
            let canMove: Bool
            if let stopAfter = preferences.cursorStopAfterSeconds,
               let movementStartedAt {
                canMove = now.timeIntervalSince(movementStartedAt) < Double(stopAfter)
            } else {
                canMove = true
            }
            let intervalElapsed = lastMovementAt.map {
                now.timeIntervalSince($0) >= Double(preferences.cursorMovementIntervalSeconds)
            } ?? true
            if canMove, intervalElapsed {
                guard performer.isAccessibilityTrusted else {
                    lastErrorMessage = L("Accessibility Permission Required for Cursor")
                    return
                }
                if movementStartedAt == nil { movementStartedAt = now }
                performer.moveCursor(speed: preferences.cursorMovementSpeed)
                lastMovementAt = now
            }
        }

        guard preferences.screenLockEnabled,
              !didLockCurrentSession,
              lockIdle >= Double(preferences.screenLockInactivityThresholdSeconds) else {
            return
        }
        guard performer.isAccessibilityTrusted else {
            lastErrorMessage = L("Accessibility Permission Required for Screen Lock")
            return
        }
        performer.lockScreen()
        didLockCurrentSession = true
    }

    private func reconcileDisplaySleepForLockedScreen(
        session: AwakeSession,
        isLocked: Bool
    ) {
        let shouldTemporarilyAllow = preferences.screenLockEnabled
            && preferences.allowsDisplaySleepWhenLocked
            && isLocked
        if shouldTemporarilyAllow {
            guard displaySleepBeforeLock == nil else { return }
            displaySleepBeforeLock = session.options.allowsDisplaySleep
            guard !session.options.allowsDisplaySleep else { return }
            do {
                try sessions.setDisplaySleepAllowed(true)
                lastErrorMessage = nil
            } catch {
                displaySleepBeforeLock = nil
                lastErrorMessage = error.localizedDescription
            }
            return
        }

        guard let originalValue = displaySleepBeforeLock else { return }
        displaySleepBeforeLock = nil
        guard sessions.activeSession?.options.allowsDisplaySleep != originalValue else { return }
        do {
            try sessions.setDisplaySleepAllowed(originalValue)
            lastErrorMessage = nil
        } catch {
            displaySleepBeforeLock = originalValue
            lastErrorMessage = error.localizedDescription
        }
    }

    private func handleClosedDisplayState(_ state: ClosedDisplayHardwareState) {
        if state != .closed {
            didLockCurrentSession = false
            return
        }
        guard state == .closed,
              preferences.lockOnClosedDisplay,
              let session = sessions.activeSession,
              !session.options.allowsClosedDisplaySleep,
              !didLockCurrentSession else { return }
        guard performer.isAccessibilityTrusted else {
            lastErrorMessage = L("Accessibility Permission Required for Screen Lock")
            return
        }
        performer.lockScreen()
        didLockCurrentSession = true
    }
}

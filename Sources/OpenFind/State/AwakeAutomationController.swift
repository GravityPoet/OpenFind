import AppKit
import Foundation

@MainActor
protocol LowBatteryPrompting: AnyObject {
    func shouldEndSession(batteryPercentage: Int) async -> Bool
}

@MainActor
final class LowBatteryAlertPrompt: LowBatteryPrompting {
    func shouldEndSession(batteryPercentage: Int) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Battery Charge Is Low")
        alert.informativeText = String(
            format: L("Low Battery End Prompt Format"),
            batteryPercentage
        )
        alert.addButton(withTitle: L("End Awake Session"))
        alert.addButton(withTitle: L("Continue Session"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class AwakeAutomationController {
    private let sessions: AwakeSessionController
    private let preferences: AwakeSessionPreferences
    private let workspaceCenter: NotificationCenter
    private let powerMonitor: any PowerSourceMonitoring
    private let lowBatteryPrompt: any LowBatteryPrompting
    private var observers: [NSObjectProtocol] = []
    private var sessionOperationTask: Task<Void, Never>?
    private var ignoredLowBatterySessionID: UUID?
    private var shouldRestartAfterPowerReconnect = false
    private var hasStarted = false

    init(
        sessions: AwakeSessionController,
        preferences: AwakeSessionPreferences,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        powerMonitor: any PowerSourceMonitoring = SystemPowerSourceMonitor(),
        lowBatteryPrompt: any LowBatteryPrompting = LowBatteryAlertPrompt()
    ) {
        self.sessions = sessions
        self.preferences = preferences
        self.workspaceCenter = workspaceCenter
        self.powerMonitor = powerMonitor
        self.lowBatteryPrompt = lowBatteryPrompt
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleForcedSleep() }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSessionResign() }
            },
        ]
        powerMonitor.start { [weak self] snapshot in
            self?.handlePowerSnapshot(snapshot)
        }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        for observer in observers { workspaceCenter.removeObserver(observer) }
        observers.removeAll()
        powerMonitor.stop()
        sessionOperationTask?.cancel()
        sessionOperationTask = nil
    }

    func handleApplicationLaunch() {
        guard preferences.startsSessionAtLaunch else { return }
        startDefaultSessionIfIdle(source: .applicationLaunch)
    }

    func handleWake() {
        guard preferences.startsSessionAfterWake else { return }
        startDefaultSessionIfIdle(source: .wake)
    }

    func handleForcedSleep() {
        guard preferences.endsSessionOnForcedSleep else { return }
        endNonTriggerSession(reason: .forcedSleep)
    }

    func handleSessionResign() {
        guard preferences.endsSessionOnSessionResign else { return }
        endNonTriggerSession(reason: .sessionResign)
    }

    func handlePowerSnapshot(_ snapshot: PowerSourceSnapshot) {
        if snapshot.adapterConnected == true {
            guard shouldRestartAfterPowerReconnect else { return }
            if sessions.isActive {
                shouldRestartAfterPowerReconnect = false
                return
            }
            guard preferences.restartsSessionAfterACReconnect else {
                shouldRestartAfterPowerReconnect = false
                return
            }
            shouldRestartAfterPowerReconnect = false
            startDefaultSessionIfIdle(source: .powerAdapter)
            return
        }

        guard preferences.lowBatteryEndEnabled,
              let session = sessions.activeSession,
              !isTriggerSession(session),
              ignoredLowBatterySessionID != session.id,
              let percentage = snapshot.batteryPercentage else { return }
        if preferences.ignoresLowBatteryWhileOnAC,
           snapshot.adapterConnected != false {
            return
        }
        let thresholdReached = preferences.lowBatteryThreshold == 100
            ? snapshot.adapterConnected == false
            : percentage < Double(preferences.lowBatteryThreshold)
        guard thresholdReached, sessionOperationTask == nil else { return }

        let sessionID = session.id
        sessionOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let shouldEnd: Bool
            if self.preferences.promptsBeforeLowBatteryEnd {
                shouldEnd = await self.lowBatteryPrompt.shouldEndSession(
                    batteryPercentage: Int(percentage.rounded())
                )
            } else {
                shouldEnd = true
            }
            guard !Task.isCancelled,
                  self.sessions.activeSession?.id == sessionID else {
                self.sessionOperationTask = nil
                return
            }
            guard shouldEnd else {
                self.ignoredLowBatterySessionID = sessionID
                self.sessionOperationTask = nil
                return
            }
            if await self.sessions.requestEndAsync(reason: .lowBattery) {
                self.shouldRestartAfterPowerReconnect = true
                self.ignoredLowBatterySessionID = nil
            }
            self.sessionOperationTask = nil
        }
    }

    private func startDefaultSessionIfIdle(source: AwakeSessionSource) {
        guard !sessions.isActive, sessionOperationTask == nil else { return }
        sessionOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.sessions.requestStartAsync(
                self.preferences.defaultRequest(source: source)
            )
            self.sessionOperationTask = nil
        }
    }

    private func endNonTriggerSession(reason: AwakeSessionEndReason) {
        guard let session = sessions.activeSession,
              !isTriggerSession(session),
              sessionOperationTask == nil else { return }
        sessionOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.sessions.requestEndAsync(reason: reason)
            self.sessionOperationTask = nil
        }
    }

    private func isTriggerSession(_ session: AwakeSession) -> Bool {
        if case .trigger = session.source { return true }
        return false
    }
}

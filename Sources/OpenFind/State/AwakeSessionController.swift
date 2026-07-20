import Foundation
import Observation

@MainActor
@Observable
final class AwakeSessionController {
    @ObservationIgnored private let assertions: any PowerAssertionControlling
    @ObservationIgnored private let applicationMonitor: any ApplicationConditionMonitoring
    @ObservationIgnored private let downloadMonitor: any FileDownloadConditionMonitoring
    @ObservationIgnored private let closedDisplay: any ClosedDisplayModeManaging
    @ObservationIgnored private let closedDisplayPowerMonitor: any PowerSourceMonitoring
    @ObservationIgnored private let screenSaver: any ScreenSaverControlling
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let dateProvider: @MainActor () -> Date
    @ObservationIgnored private let uptimeProvider: @MainActor () -> TimeInterval
    @ObservationIgnored private let systemClockPollInterval: TimeInterval
    @ObservationIgnored private let operationGate = AwakeSessionOperationGate()
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var systemClockObserver: NSObjectProtocol?
    @ObservationIgnored private var timerDeadlineUptime: TimeInterval?
    @ObservationIgnored private var conditionObservation: (any SessionConditionObservation)?
    @ObservationIgnored private var eventObservers: [UUID: @MainActor (AwakeSessionEvent) -> Void] = [:]
    @ObservationIgnored private var closedDisplayPowerTask: Task<Void, Never>?
    private var hasReceivedInitialClosedDisplayPowerSnapshot = false

    private(set) var activeSession: AwakeSession?
    private(set) var lastErrorMessage: String?

    init(
        assertions: any PowerAssertionControlling = PowerAssertionEngine(),
        applicationMonitor: any ApplicationConditionMonitoring = WorkspaceApplicationConditionMonitor(),
        downloadMonitor: any FileDownloadConditionMonitoring = PollingFileDownloadConditionMonitor(),
        closedDisplay: any ClosedDisplayModeManaging = ClosedDisplayModeController(),
        closedDisplayPowerMonitor: any PowerSourceMonitoring = SystemPowerSourceMonitor(),
        screenSaver: any ScreenSaverControlling = ScreenSaverSessionController(),
        notificationCenter: NotificationCenter = .default,
        dateProvider: @escaping @MainActor () -> Date = { Date() },
        uptimeProvider: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        systemClockPollInterval: TimeInterval = 60
    ) {
        self.assertions = assertions
        self.applicationMonitor = applicationMonitor
        self.downloadMonitor = downloadMonitor
        self.closedDisplay = closedDisplay
        self.closedDisplayPowerMonitor = closedDisplayPowerMonitor
        self.screenSaver = screenSaver
        self.notificationCenter = notificationCenter
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
        self.systemClockPollInterval = systemClockPollInterval.isFinite
            ? max(0.01, systemClockPollInterval)
            : 60
    }

    var isActive: Bool {
        activeSession != nil
    }

    var closedDisplayModeSupported: Bool {
        closedDisplay.isSupported
    }

    var allowsClosedDisplaySleep: Bool {
        activeSession?.options.allowsClosedDisplaySleep ?? true
    }

    var allowsScreenSaver: Bool {
        guard let policy = activeSession?.options.screenSaverPolicy else { return false }
        if case .allow = policy { return true }
        return false
    }

    func start(_ request: AwakeSessionRequest, at now: Date = Date()) throws {
        var request = request
        request.options = try request.options.validated()
        let endCondition = try prepareEndCondition(for: request, at: now)
        guard !operationGate.isOccupied else {
            throw AwakeSessionValidationError.powerTransitionInProgress
        }
        guard request.options.allowsClosedDisplaySleep,
              activeSession?.options.allowsClosedDisplaySleep != false,
              !closedDisplay.hasPendingRestoration else {
            throw AwakeSessionValidationError.closedDisplayRequiresAsync
        }
        try startPreparedSession(request, endCondition: endCondition, at: now)
    }

    func startAsync(_ request: AwakeSessionRequest, at now: Date = Date()) async throws {
        var request = request
        request.options = try request.options.validated()
        let endCondition = try prepareEndCondition(for: request, at: now)
        await operationGate.enter()
        defer { operationGate.leave() }
        try Task.checkCancellation()

        let previouslyPrevented = activeSession?.options.allowsClosedDisplaySleep == false
            || closedDisplay.hasPendingRestoration
        let shouldPrevent = !request.options.allowsClosedDisplaySleep
        let transitionNeeded = previouslyPrevented != shouldPrevent

        do {
            if transitionNeeded {
                if shouldPrevent {
                    try await closedDisplay.enable()
                } else {
                    try await closedDisplay.disable()
                }
                try Task.checkCancellation()
            }
            try validateLiveCondition(endCondition)
            try startPreparedSession(request, endCondition: endCondition, at: now)
        } catch {
            guard transitionNeeded else { throw error }
            do {
                if previouslyPrevented {
                    try await closedDisplay.enable()
                } else {
                    try await closedDisplay.disable()
                }
            } catch let rollbackError {
                throw AwakeSessionRollbackError(operation: error, rollback: rollbackError)
            }
            throw error
        }
    }

    func end(reason: AwakeSessionEndReason = .requested) throws {
        guard !operationGate.isOccupied else {
            throw AwakeSessionValidationError.powerTransitionInProgress
        }
        guard activeSession?.options.allowsClosedDisplaySleep != false,
              !closedDisplay.hasPendingRestoration else {
            throw AwakeSessionValidationError.closedDisplayRequiresAsync
        }
        try assertions.deactivate()
        clearSessionLifecycle(reason: reason)
    }

    func endAsync(reason: AwakeSessionEndReason = .requested) async throws {
        await operationGate.enter()
        defer { operationGate.leave() }
        try Task.checkCancellation()

        let shouldRestoreClosedDisplay = activeSession?.options.allowsClosedDisplaySleep == false
            || closedDisplay.hasPendingRestoration
        guard shouldRestoreClosedDisplay else {
            try assertions.deactivate()
            clearSessionLifecycle(reason: reason)
            return
        }

        let shouldReenableAfterAssertionFailure =
            activeSession?.options.allowsClosedDisplaySleep == false
        do {
            try await closedDisplay.disable()
            try Task.checkCancellation()
            try assertions.deactivate()
        } catch {
            guard shouldReenableAfterAssertionFailure else { throw error }
            do {
                try await closedDisplay.enable()
            } catch let rollbackError {
                throw AwakeSessionRollbackError(operation: error, rollback: rollbackError)
            }
            throw error
        }
        clearSessionLifecycle(reason: reason)
    }

    func setClosedDisplaySleepAllowed(_ allowed: Bool) async throws {
        await operationGate.enter()
        defer { operationGate.leave() }
        try Task.checkCancellation()

        guard var session = activeSession,
              session.options.allowsClosedDisplaySleep != allowed else { return }
        do {
            if allowed {
                try await closedDisplay.disable()
            } else {
                try await closedDisplay.enable()
            }
            try Task.checkCancellation()
        } catch let operationError {
            do {
                if allowed {
                    try await closedDisplay.enable()
                } else {
                    try await closedDisplay.disable()
                }
            } catch let rollbackError {
                throw AwakeSessionRollbackError(
                    operation: operationError,
                    rollback: rollbackError
                )
            }
            throw operationError
        }
        session.options.allowsClosedDisplaySleep = allowed
        activeSession = session
        configureClosedDisplayPowerMonitoring(for: session)
        emit(.updated(session))
    }

    func setScreenSaverPolicy(_ policy: ScreenSaverPolicy) {
        guard var session = activeSession else { return }
        session.options.screenSaverPolicy = policy
        activeSession = session
        screenSaver.start(
            policy: policy,
            exceptionIdentifiers: session.options.screenSaverExceptionIdentifiers
        )
        emit(.updated(session))
    }

    func requestClosedDisplaySleepAllowed(_ allowed: Bool) {
        Task { @MainActor [weak self] in
            do {
                try await self?.setClosedDisplaySleepAllowed(allowed)
                self?.lastErrorMessage = nil
            } catch {
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    func requestScreenSaverAllowed(_ allowed: Bool) {
        setScreenSaverPolicy(allowed ? .allow(after: 15 * 60) : .prevent)
        lastErrorMessage = nil
    }

    func recoverClosedDisplayState() async -> Bool {
        await operationGate.enter()
        defer { operationGate.leave() }
        let recovered = await closedDisplay.recoverIfNeeded()
        if !recovered {
            lastErrorMessage = ClosedDisplayModeError.recoveryFailed.localizedDescription
        }
        return recovered
    }

    private func clearSessionLifecycle(reason: AwakeSessionEndReason) {
        let endedSession = activeSession
        stopClosedDisplayPowerMonitoring()
        screenSaver.stop()
        clearDeadlineScheduling()
        conditionObservation?.cancel()
        conditionObservation = nil
        activeSession = nil
        lastErrorMessage = nil
        if let endedSession { emit(.ended(endedSession, reason: reason)) }
    }

    func setDisplaySleepAllowed(_ allowed: Bool) throws {
        try setDisplaySleepAllowed(allowed, remaining: remainingTime())
    }

    func setDisplaySleepAllowed(_ allowed: Bool, at now: Date) throws {
        try setDisplaySleepAllowed(
            allowed,
            remaining: activeSession?.remainingTime(at: now)
        )
    }

    private func setDisplaySleepAllowed(
        _ allowed: Bool,
        remaining: TimeInterval?
    ) throws {
        guard !operationGate.isOccupied else {
            throw AwakeSessionValidationError.powerTransitionInProgress
        }
        guard var session = activeSession else { return }
        if session.deadline != nil, let remaining, remaining <= 0 {
            try end(reason: .deadline)
            return
        }
        let timeout = assertionTimeout(for: session, remaining: remaining)
        try assertions.activate(
            PowerAssertionConfiguration(allowsDisplaySleep: allowed, timeout: timeout)
        )
        session.options.allowsDisplaySleep = allowed
        activeSession = session
        emit(.updated(session))
    }

    func remainingTime() -> TimeInterval? {
        guard let session = activeSession else { return nil }
        if case .after = session.endCondition,
           session.options.endTimeCalculation == .timer,
           let timerDeadlineUptime {
            return max(0, timerDeadlineUptime - uptimeProvider())
        }
        return session.remainingTime(at: dateProvider())
    }

    func remainingTime(at date: Date) -> TimeInterval? {
        activeSession?.remainingTime(at: date)
    }

    func extend(by additionalTime: TimeInterval) throws {
        try extend(
            by: additionalTime,
            at: dateProvider(),
            remaining: remainingTime()
        )
    }

    func extend(by additionalTime: TimeInterval, at now: Date) throws {
        try extend(
            by: additionalTime,
            at: now,
            remaining: activeSession?.remainingTime(at: now)
        )
    }

    private func extend(
        by additionalTime: TimeInterval,
        at now: Date,
        remaining: TimeInterval?
    ) throws {
        guard !operationGate.isOccupied else {
            throw AwakeSessionValidationError.powerTransitionInProgress
        }
        guard additionalTime.isFinite, additionalTime > 0 else {
            throw AwakeSessionValidationError.invalidDuration
        }
        guard let session = activeSession,
              let remaining,
              remaining > 0 else {
            throw AwakeSessionValidationError.sessionCannotBeExtended
        }

        let extendedCondition: AwakeSessionEndCondition
        switch session.endCondition {
        case .after:
            let duration = remaining + additionalTime
            guard duration.isFinite else {
                throw AwakeSessionValidationError.invalidDuration
            }
            extendedCondition = .after(duration)
        case let .at(deadline):
            let extendedDeadline = deadline.addingTimeInterval(additionalTime)
            guard extendedDeadline.timeIntervalSince(now).isFinite else {
                throw AwakeSessionValidationError.invalidEndDate
            }
            extendedCondition = .at(extendedDeadline)
        case .indefinitely, .whileApplicationRuns, .whileFileDownloads:
            throw AwakeSessionValidationError.sessionCannotBeExtended
        }

        let request = AwakeSessionRequest(
            endCondition: extendedCondition,
            options: session.options,
            source: session.source
        )
        let preparedCondition = try prepareEndCondition(for: request, at: now)
        try startPreparedSession(request, endCondition: preparedCondition, at: now)
    }

    private func prepareEndCondition(
        for request: AwakeSessionRequest,
        at now: Date
    ) throws -> AwakeSessionEndCondition {
        let endCondition = try request.endCondition.validated(at: now)
        try validateLiveCondition(endCondition)
        return endCondition
    }

    private func validateLiveCondition(_ endCondition: AwakeSessionEndCondition) throws {
        switch endCondition {
        case let .whileApplicationRuns(bundleIdentifier):
            guard applicationMonitor.isRunning(bundleIdentifier: bundleIdentifier) else {
                throw AwakeSessionValidationError.conditionNotMet
            }
        case let .whileFileDownloads(url, _):
            guard downloadMonitor.isMonitorable(url) else {
                throw AwakeSessionValidationError.conditionNotMet
            }
        case .indefinitely, .after, .at:
            break
        }
    }

    private func startPreparedSession(
        _ request: AwakeSessionRequest,
        endCondition: AwakeSessionEndCondition,
        at now: Date
    ) throws {
        let timeout = assertionTimeout(
            for: endCondition,
            options: request.options
        )
        try assertions.activate(
            PowerAssertionConfiguration(
                allowsDisplaySleep: request.options.allowsDisplaySleep,
                timeout: timeout
            )
        )

        let previousSession = activeSession
        let session = AwakeSession(
            id: UUID(),
            startedAt: now,
            endCondition: endCondition,
            options: request.options,
            source: request.source
        )
        activeSession = session
        lastErrorMessage = nil
        screenSaver.start(
            policy: request.options.screenSaverPolicy,
            exceptionIdentifiers: request.options.screenSaverExceptionIdentifiers
        )
        configureClosedDisplayPowerMonitoring(for: session)
        conditionObservation?.cancel()
        conditionObservation = nil
        scheduleDeadline(for: session)
        if case let .whileApplicationRuns(bundleIdentifier) = endCondition {
            observeApplication(bundleIdentifier: bundleIdentifier, sessionID: session.id)
        } else if case let .whileFileDownloads(url, inactivityTimeout) = endCondition {
            observeDownload(
                url: url,
                inactivityTimeout: inactivityTimeout,
                sessionID: session.id
            )
        }
        if let previousSession {
            emit(.replaced(previous: previousSession, current: session))
        } else {
            emit(.started(session))
        }
    }

    private func observeApplication(bundleIdentifier: String, sessionID: UUID) {
        conditionObservation = applicationMonitor.observe(bundleIdentifier: bundleIdentifier) {
            [weak self] isRunning in
            guard !isRunning else { return }
            self?.endAutomatically(sessionID: sessionID, reason: .condition)
        }
        if !applicationMonitor.isRunning(bundleIdentifier: bundleIdentifier) {
            endAutomatically(sessionID: sessionID, reason: .condition)
        }
    }

    private func observeDownload(
        url: URL,
        inactivityTimeout: TimeInterval,
        sessionID: UUID
    ) {
        conditionObservation = downloadMonitor.observe(
            url,
            inactivityTimeout: inactivityTimeout
        ) { [weak self] in
            self?.endAutomatically(sessionID: sessionID, reason: .condition)
        }
    }

    private func assertionTimeout(
        for endCondition: AwakeSessionEndCondition,
        options: AwakeSessionOptions
    ) -> TimeInterval {
        guard case let .after(seconds) = endCondition,
              options.endTimeCalculation == .timer else { return 0 }
        return seconds
    }

    private func assertionTimeout(
        for session: AwakeSession,
        remaining: TimeInterval?
    ) -> TimeInterval {
        guard case .after = session.endCondition,
              session.options.endTimeCalculation == .timer else { return 0 }
        return remaining ?? 0
    }

    private func scheduleDeadline(for session: AwakeSession) {
        clearDeadlineScheduling()
        switch session.endCondition {
        case let .after(seconds) where session.options.endTimeCalculation == .timer:
            let deadlineUptime = uptimeProvider() + seconds
            timerDeadlineUptime = deadlineUptime
            scheduleTimerDeadline(sessionID: session.id, deadlineUptime: deadlineUptime)
        case .after, .at:
            guard let deadline = session.deadline else { return }
            scheduleSystemClockDeadline(sessionID: session.id, deadline: deadline)
        case .indefinitely, .whileApplicationRuns, .whileFileDownloads:
            return
        }
    }

    private func scheduleTimerDeadline(sessionID: UUID, deadlineUptime: TimeInterval) {
        let delay = max(0, deadlineUptime - uptimeProvider())
        deadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self?.activeSession?.id == sessionID else { return }
                try await self?.endAsync(reason: .deadline)
            } catch is CancellationError {
                return
            } catch {
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleSystemClockDeadline(sessionID: UUID, deadline: Date) {
        systemClockObserver = notificationCenter.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSession?.id == sessionID else { return }
                self.deadlineTask?.cancel()
                self.startSystemClockDeadlineTask(sessionID: sessionID, deadline: deadline)
            }
        }
        startSystemClockDeadlineTask(sessionID: sessionID, deadline: deadline)
    }

    private func startSystemClockDeadlineTask(sessionID: UUID, deadline: Date) {
        deadlineTask = Task { @MainActor [weak self] in
            do {
                while let self,
                      !Task.isCancelled,
                      self.activeSession?.id == sessionID {
                    let remaining = deadline.timeIntervalSince(self.dateProvider())
                    if remaining <= 0 {
                        try await self.endAsync(reason: .deadline)
                        return
                    }
                    try await Task.sleep(
                        for: .seconds(min(remaining, self.systemClockPollInterval))
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func clearDeadlineScheduling() {
        deadlineTask?.cancel()
        deadlineTask = nil
        timerDeadlineUptime = nil
        if let systemClockObserver {
            notificationCenter.removeObserver(systemClockObserver)
            self.systemClockObserver = nil
        }
    }

    private func endAutomatically(sessionID: UUID, reason: AwakeSessionEndReason) {
        Task { @MainActor [weak self] in
            guard let self, self.activeSession?.id == sessionID else { return }
            do {
                try await self.endAsync(reason: reason)
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func configureClosedDisplayPowerMonitoring(for session: AwakeSession) {
        guard !session.options.allowsClosedDisplaySleep else {
            stopClosedDisplayPowerMonitoring()
            return
        }
        closedDisplayPowerMonitor.stop()
        hasReceivedInitialClosedDisplayPowerSnapshot = false
        closedDisplayPowerMonitor.start { [weak self] _ in
            guard let self else { return }
            guard self.hasReceivedInitialClosedDisplayPowerSnapshot else {
                self.hasReceivedInitialClosedDisplayPowerSnapshot = true
                return
            }
            self.reconcileClosedDisplayAfterPowerChange(sessionID: session.id)
        }
    }

    private func stopClosedDisplayPowerMonitoring() {
        closedDisplayPowerMonitor.stop()
        hasReceivedInitialClosedDisplayPowerSnapshot = false
        closedDisplayPowerTask?.cancel()
        closedDisplayPowerTask = nil
    }

    private func reconcileClosedDisplayAfterPowerChange(sessionID: UUID) {
        guard closedDisplayPowerTask == nil else { return }
        closedDisplayPowerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.operationGate.enter()
            defer {
                self.operationGate.leave()
                self.closedDisplayPowerTask = nil
            }
            guard !Task.isCancelled,
                  let session = self.activeSession,
                  session.id == sessionID,
                  !session.options.allowsClosedDisplaySleep else { return }
            guard await self.closedDisplay.reconcileAfterPowerSourceChange() else {
                do {
                    try await self.closedDisplay.disable()
                    try self.assertions.deactivate()
                    self.clearSessionLifecycle(reason: .closedDisplayPowerChange)
                    self.lastErrorMessage = ClosedDisplayModeError.powerChangeUnprotected
                        .localizedDescription
                } catch is CancellationError {
                    return
                } catch {
                    self.lastErrorMessage = error.localizedDescription
                }
                return
            }
        }
    }

    func requestStart(_ request: AwakeSessionRequest) {
        if requiresAsyncPowerTransition(for: request) {
            Task { @MainActor [weak self] in
                _ = await self?.requestStartAsync(request)
            }
            return
        }
        do {
            try start(request)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func requestStartAsync(_ request: AwakeSessionRequest) async -> Bool {
        do {
            try Task.checkCancellation()
            if requiresAsyncPowerTransition(for: request) {
                try await startAsync(request)
            } else {
                try start(request)
            }
            lastErrorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func requestEnd(reason: AwakeSessionEndReason = .requested) {
        Task { @MainActor [weak self] in
            _ = await self?.requestEndAsync(reason: reason)
        }
    }

    @discardableResult
    func requestEndAsync(reason: AwakeSessionEndReason = .requested) async -> Bool {
        do {
            try await endAsync(reason: reason)
            lastErrorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func requestDisplaySleepAllowed(_ allowed: Bool) {
        do {
            try setDisplaySleepAllowed(allowed)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func requestExtend(by additionalTime: TimeInterval) {
        do {
            try extend(by: additionalTime)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func observeEvents(
        _ observer: @escaping @MainActor (AwakeSessionEvent) -> Void
    ) -> AwakeSessionEventSubscription {
        let identifier = UUID()
        eventObservers[identifier] = observer
        return AwakeSessionEventSubscription { [weak self] in
            self?.eventObservers.removeValue(forKey: identifier)
        }
    }

    private func emit(_ event: AwakeSessionEvent) {
        for observer in eventObservers.values { observer(event) }
    }

    private func requiresAsyncPowerTransition(for request: AwakeSessionRequest) -> Bool {
        !request.options.allowsClosedDisplaySleep
            || activeSession?.options.allowsClosedDisplaySleep == false
            || closedDisplay.hasPendingRestoration
    }
}

@MainActor
final class AwakeSessionEventSubscription {
    private var cancellation: (@MainActor () -> Void)?

    init(cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

struct AwakeSessionRollbackError: LocalizedError {
    let operation: any Error
    let rollback: any Error

    var errorDescription: String? {
        "The session operation failed and restoring its previous power state also failed. "
            + "Operation: \(operation.localizedDescription) Rollback: \(rollback.localizedDescription)"
    }
}

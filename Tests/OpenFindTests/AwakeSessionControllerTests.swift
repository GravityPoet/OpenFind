import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Awake Session Controller Tests")
struct AwakeSessionControllerTests {
    @Test func startsAnIndefiniteSession() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        let start = Date(timeIntervalSince1970: 1_000)

        try controller.start(.init(), at: start)

        #expect(controller.isActive)
        #expect(controller.activeSession?.startedAt == start)
        #expect(assertions.activations == [.init(allowsDisplaySleep: false, timeout: 0)])
        #expect(controller.remainingTime(at: start) == nil)
    }

    @Test func timedSessionUsesTheSameDeadlineForStateAndAssertion() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        let start = Date(timeIntervalSince1970: 1_000)

        try controller.start(.init(endCondition: .after(120)), at: start)

        #expect(assertions.activations.last?.timeout == 120)
        #expect(controller.remainingTime(at: start.addingTimeInterval(30)) == 90)
    }

    @Test func timerCalculationUsesMonotonicElapsedTime() throws {
        let assertions = FakePowerAssertionController()
        let uptime = MutableUptime(10_000)
        let controller = AwakeSessionController(
            assertions: assertions,
            uptimeProvider: { uptime.value }
        )
        let start = Date(timeIntervalSince1970: 1_000)

        try controller.start(.init(endCondition: .after(120)), at: start)
        uptime.value += 45

        #expect(controller.remainingTime() == 75)
        #expect(assertions.activations.last?.timeout == 120)
    }

    @Test func systemClockCalculationUsesIndefiniteAssertionAndEndsAfterClockJump() async throws {
        let assertions = FakePowerAssertionController()
        let center = NotificationCenter()
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = MutableWallClock(start)
        let controller = AwakeSessionController(
            assertions: assertions,
            notificationCenter: center,
            dateProvider: { clock.now },
            systemClockPollInterval: 60
        )
        let options = AwakeSessionOptions(
            allowsDisplaySleep: false,
            endTimeCalculation: .systemClock
        )

        try controller.start(.init(endCondition: .after(120), options: options), at: start)
        #expect(assertions.activations.last?.timeout == 0)
        #expect(controller.remainingTime() == 120)

        clock.now = start.addingTimeInterval(121)
        center.post(name: .NSSystemClockDidChange, object: nil)

        try await waitUntil { !controller.isActive }
        #expect(assertions.deactivationCount == 1)
    }

    @Test func absoluteDateSessionUsesControllerOwnedWallClockDeadline() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        let start = Date(timeIntervalSince1970: 1_000)

        try controller.start(.init(endCondition: .at(start.addingTimeInterval(120))), at: start)

        #expect(assertions.activations.last?.timeout == 0)
        #expect(controller.remainingTime(at: start.addingTimeInterval(30)) == 90)
    }

    @Test func timedSessionExtensionTransactionallyReplacesTheSession() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        let start = Date(timeIntervalSince1970: 1_000)
        try controller.start(.init(endCondition: .after(120)), at: start)
        let originalID = try #require(controller.activeSession?.id)

        try controller.extend(by: 60, at: start.addingTimeInterval(30))

        #expect(controller.activeSession?.id != originalID)
        #expect(controller.remainingTime(at: start.addingTimeInterval(30)) == 150)
        #expect(assertions.activations.last?.timeout == 150)
    }

    @Test func failedTimedSessionExtensionPreservesTheExistingSession() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        let start = Date(timeIntervalSince1970: 1_000)
        try controller.start(.init(endCondition: .after(120)), at: start)
        let existing = try #require(controller.activeSession)
        assertions.activationError = .invalidTimeout

        #expect(throws: PowerAssertionError.invalidTimeout) {
            try controller.extend(by: 60, at: start.addingTimeInterval(30))
        }
        #expect(controller.activeSession == existing)
    }

    @Test func onlyTimedSessionsCanBeExtended() throws {
        let controller = AwakeSessionController(assertions: FakePowerAssertionController())
        try controller.start(.init())

        #expect(throws: AwakeSessionValidationError.sessionCannotBeExtended) {
            try controller.extend(by: 60)
        }
    }

    @Test func failedReplacementLeavesTheExistingSessionUntouched() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        try controller.start(.init())
        let existing = try #require(controller.activeSession)
        assertions.activationError = .invalidTimeout

        #expect(throws: PowerAssertionError.invalidTimeout) {
            try controller.start(.init(endCondition: .after(10)))
        }
        #expect(controller.activeSession == existing)
    }

    @Test func conditionBasedSessionsRequireTheirMonitor() {
        let appMonitor = FakeApplicationConditionMonitor()
        let controller = AwakeSessionController(
            assertions: FakePowerAssertionController(),
            applicationMonitor: appMonitor
        )

        #expect(throws: AwakeSessionValidationError.conditionNotMet) {
            try controller.start(.init(endCondition: .whileApplicationRuns(bundleIdentifier: "com.apple.TextEdit")))
        }
        #expect(throws: AwakeSessionValidationError.conditionNotMet) {
            try controller.start(.init(endCondition: .whileFileDownloads(
                URL(fileURLWithPath: "/tmp/OpenFind-missing-\(UUID())"),
                inactivityTimeout: 60
            )))
        }
        #expect(!controller.isActive)
    }

    @Test func fileDownloadSessionEndsAfterTheConfiguredInactivityTimeout() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDownload.\(UUID())")
        try Data("partial".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)

        try controller.start(.init(endCondition: .whileFileDownloads(
            url,
            inactivityTimeout: 0.03
        )))
        #expect(controller.isActive)

        try await waitUntil { !controller.isActive }
        #expect(!controller.isActive)
        #expect(assertions.deactivationCount == 1)
    }

    @Test func applicationSessionEndsWhenTheApplicationTerminates() async throws {
        let assertions = FakePowerAssertionController()
        let appMonitor = FakeApplicationConditionMonitor()
        appMonitor.runningBundleIdentifiers.insert("com.apple.TextEdit")
        let controller = AwakeSessionController(
            assertions: assertions,
            applicationMonitor: appMonitor
        )

        try controller.start(
            .init(endCondition: .whileApplicationRuns(bundleIdentifier: "com.apple.TextEdit"))
        )
        #expect(controller.isActive)

        appMonitor.setRunning(false, bundleIdentifier: "com.apple.TextEdit")
        try await waitUntil { !controller.isActive }
        #expect(!controller.isActive)
        #expect(assertions.deactivationCount == 1)
    }

    @Test func backgroundProcessSessionUsesPollingWhenWorkspaceHasNoLifecycleEvent() async throws {
        let identifier = "openfind-background-\(UUID().uuidString)"
        let processes = MutableApplicationProcessNames([identifier])
        let monitor = WorkspaceApplicationConditionMonitor(
            workspace: .shared,
            processNames: { processes.names },
            pollInterval: 0.01
        )
        let controller = AwakeSessionController(
            assertions: FakePowerAssertionController(),
            applicationMonitor: monitor
        )
        try controller.start(.init(
            endCondition: .whileApplicationRuns(bundleIdentifier: identifier)
        ))
        #expect(controller.isActive)

        processes.names = []
        try await waitUntil { !controller.isActive }
        #expect(!controller.isActive)
    }

    @Test func timedSessionEndsAutomatically() async throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        try controller.start(.init(endCondition: .after(0.01)))

        try await waitUntil { !controller.isActive }

        #expect(!controller.isActive)
        #expect(assertions.deactivationCount == 1)
    }

    @Test func changingDisplayPolicyReusesTheRemainingDeadline() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        let start = Date(timeIntervalSince1970: 1_000)
        try controller.start(.init(endCondition: .after(120)), at: start)

        try controller.setDisplaySleepAllowed(true, at: start.addingTimeInterval(45))

        #expect(assertions.activations.last == .init(allowsDisplaySleep: true, timeout: 75))
        #expect(controller.activeSession?.options.allowsDisplaySleep == true)
    }

    @Test func screenSaverPolicyStartsUpdatesAndStopsWithTheSession() throws {
        let screenSaver = FakeScreenSaverController()
        let controller = AwakeSessionController(
            assertions: FakePowerAssertionController(),
            screenSaver: screenSaver
        )
        let initialPolicy = ScreenSaverPolicy.allow(after: 90)

        try controller.start(.init(options: .init(
            allowsDisplaySleep: false,
            screenSaverPolicy: initialPolicy
        )))
        #expect(screenSaver.startedPolicies == [initialPolicy])
        #expect(controller.allowsScreenSaver)

        controller.setScreenSaverPolicy(.prevent)
        #expect(screenSaver.startedPolicies == [initialPolicy, .prevent])
        #expect(!controller.allowsScreenSaver)

        try controller.end()
        #expect(screenSaver.stopCount == 1)
    }

    @Test func releaseFailureKeepsTheSessionVisibleAndRetryable() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        try controller.start(.init())
        assertions.deactivationError = .releaseFailed([])

        #expect(throws: PowerAssertionError.self) { try controller.end() }
        #expect(controller.isActive)

        assertions.deactivationError = nil
        try controller.end()
        #expect(!controller.isActive)
    }

    @Test func menuCommandsExposeErrorsWithoutDiscardingTheActiveSession() throws {
        let assertions = FakePowerAssertionController()
        let controller = AwakeSessionController(assertions: assertions)
        try controller.start(.init())
        let existing = controller.activeSession
        assertions.activationError = .creationFailed(kind: .displaySleep, status: -99)

        controller.requestStart(.init(endCondition: .after(60)))

        #expect(controller.activeSession == existing)
        #expect(controller.lastErrorMessage?.contains("-99") == true)
        controller.clearError()
        #expect(controller.lastErrorMessage == nil)
    }

    @Test func synchronousAPIRejectsClosedDisplayPowerChanges() {
        let closedDisplay = FakeClosedDisplayModeManager()
        let controller = AwakeSessionController(
            assertions: FakePowerAssertionController(),
            closedDisplay: closedDisplay
        )
        let request = AwakeSessionRequest(
            options: .init(allowsDisplaySleep: false, allowsClosedDisplaySleep: false)
        )

        #expect(throws: AwakeSessionValidationError.closedDisplayRequiresAsync) {
            try controller.start(request)
        }
        #expect(!controller.isActive)
        #expect(closedDisplay.enableCount == 0)
    }

    @Test func asynchronousClosedDisplaySessionRestoresPowerStateOnEnd() async throws {
        let assertions = FakePowerAssertionController()
        let closedDisplay = FakeClosedDisplayModeManager()
        let controller = AwakeSessionController(
            assertions: assertions,
            closedDisplay: closedDisplay
        )
        let request = AwakeSessionRequest(
            options: .init(allowsDisplaySleep: false, allowsClosedDisplaySleep: false)
        )

        try await controller.startAsync(request)
        #expect(closedDisplay.isEnabled)
        #expect(controller.isActive)

        try await controller.endAsync()
        #expect(!closedDisplay.isEnabled)
        #expect(!controller.isActive)
        #expect(assertions.deactivationCount == 1)
    }

    @Test func failedAssertionCreationRollsBackClosedDisplayMode() async {
        let assertions = FakePowerAssertionController()
        assertions.activationError = .creationFailed(kind: .systemSleep, status: -7)
        let closedDisplay = FakeClosedDisplayModeManager()
        let controller = AwakeSessionController(
            assertions: assertions,
            closedDisplay: closedDisplay
        )
        let request = AwakeSessionRequest(
            options: .init(allowsDisplaySleep: false, allowsClosedDisplaySleep: false)
        )

        do {
            try await controller.startAsync(request)
            Issue.record("Closed-display session unexpectedly started")
        } catch let error as PowerAssertionError {
            #expect(error == .creationFailed(kind: .systemSleep, status: -7))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!closedDisplay.isEnabled)
        #expect(closedDisplay.enableCount == 1)
        #expect(closedDisplay.disableCount == 1)
        #expect(!controller.isActive)
    }

    @Test func failedAssertionReleaseReenablesClosedDisplayMode() async throws {
        let assertions = FakePowerAssertionController()
        let closedDisplay = FakeClosedDisplayModeManager()
        let controller = AwakeSessionController(
            assertions: assertions,
            closedDisplay: closedDisplay
        )
        let request = AwakeSessionRequest(
            options: .init(allowsDisplaySleep: false, allowsClosedDisplaySleep: false)
        )
        try await controller.startAsync(request)
        assertions.deactivationError = .releaseFailed([])

        do {
            try await controller.endAsync()
            Issue.record("Session unexpectedly ended after assertion release failure")
        } catch is PowerAssertionError {
            #expect(closedDisplay.isEnabled)
            #expect(controller.isActive)
        }

        assertions.deactivationError = nil
        try await controller.endAsync()
        #expect(!controller.isActive)
        #expect(!closedDisplay.isEnabled)
    }

    @Test func timedClosedDisplaySessionRestoresPowerStateAutomatically() async throws {
        let assertions = FakePowerAssertionController()
        let closedDisplay = FakeClosedDisplayModeManager()
        let controller = AwakeSessionController(
            assertions: assertions,
            closedDisplay: closedDisplay
        )
        let request = AwakeSessionRequest(
            endCondition: .after(0.01),
            options: .init(allowsDisplaySleep: false, allowsClosedDisplaySleep: false)
        )

        try await controller.startAsync(request)
        try await waitUntil { !controller.isActive }

        #expect(!controller.isActive)
        #expect(!closedDisplay.isEnabled)
        #expect(closedDisplay.disableCount == 1)
    }

    @Test func unprotectedPowerChangeEndsAClosedDisplaySessionSafely() async throws {
        let assertions = FakePowerAssertionController()
        let closedDisplay = FakeClosedDisplayModeManager()
        closedDisplay.reconcileResult = false
        let powerMonitor = FakeSessionPowerSourceMonitor()
        let controller = AwakeSessionController(
            assertions: assertions,
            closedDisplay: closedDisplay,
            closedDisplayPowerMonitor: powerMonitor
        )
        var endReason: AwakeSessionEndReason?
        let subscription = controller.observeEvents { event in
            if case let .ended(_, reason) = event { endReason = reason }
        }
        defer { subscription.cancel() }

        try await controller.startAsync(.init(options: .init(
            allowsDisplaySleep: false,
            allowsClosedDisplaySleep: false
        )))
        powerMonitor.emit(.init(batteryPercentage: 80, adapterConnected: true))

        try await waitUntil { !controller.isActive }
        #expect(!controller.isActive)
        #expect(closedDisplay.reconcileCount == 1)
        #expect(closedDisplay.disableCount == 1)
        #expect(assertions.deactivationCount == 1)
        #expect(endReason == .closedDisplayPowerChange)
        #expect(controller.lastErrorMessage?.contains("Power Protect") == true)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private final class FakePowerAssertionController: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?
    private(set) var activations: [PowerAssertionConfiguration] = []
    var activationError: PowerAssertionError?
    var deactivationError: PowerAssertionError?
    private(set) var deactivationCount = 0

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        if let activationError { throw activationError }
        activations.append(configuration)
        activeConfiguration = configuration
    }

    func deactivate() throws {
        if let deactivationError { throw deactivationError }
        deactivationCount += 1
        activeConfiguration = nil
    }
}

@MainActor
private final class MutableWallClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class MutableUptime {
    var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }
}

@MainActor
private final class MutableApplicationProcessNames {
    var names: Set<String>

    init(_ names: Set<String>) {
        self.names = names
    }
}

@MainActor
private final class FakeScreenSaverController: ScreenSaverControlling {
    private(set) var startedPolicies: [ScreenSaverPolicy] = []
    private(set) var exceptionSets: [Set<String>] = []
    private(set) var stopCount = 0

    func start(policy: ScreenSaverPolicy, exceptionIdentifiers: Set<String>) {
        startedPolicies.append(policy)
        exceptionSets.append(exceptionIdentifiers)
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeClosedDisplayModeManager: ClosedDisplayModeManaging {
    var isEnabled = false
    var hasPendingRestoration: Bool { isEnabled }
    private(set) var enableCount = 0
    private(set) var disableCount = 0
    private(set) var reconcileCount = 0
    var reconcileResult = true

    func recoverIfNeeded() async -> Bool { true }

    func reconcileAfterPowerSourceChange() async -> Bool {
        reconcileCount += 1
        return reconcileResult
    }

    func enable() async throws {
        enableCount += 1
        isEnabled = true
    }

    func disable() async throws {
        disableCount += 1
        isEnabled = false
    }
}

@MainActor
private final class FakeSessionPowerSourceMonitor: PowerSourceMonitoring {
    private var handler: (@MainActor (PowerSourceSnapshot) -> Void)?
    private var current = PowerSourceSnapshot(batteryPercentage: 80, adapterConnected: false)

    func start(handler: @escaping @MainActor (PowerSourceSnapshot) -> Void) {
        self.handler = handler
        handler(current)
    }

    func stop() {
        handler = nil
    }

    func snapshot() -> PowerSourceSnapshot { current }

    func emit(_ snapshot: PowerSourceSnapshot) {
        current = snapshot
        handler?(snapshot)
    }
}

@MainActor
private final class FakeApplicationConditionMonitor: ApplicationConditionMonitoring {
    var runningBundleIdentifiers: Set<String> = []
    private var observations: [String: FakeApplicationConditionObservation] = [:]

    func isRunning(bundleIdentifier: String) -> Bool {
        runningBundleIdentifiers.contains(bundleIdentifier)
    }

    func observe(
        bundleIdentifier: String,
        onChange: @escaping @MainActor (Bool) -> Void
    ) -> any ApplicationConditionObservation {
        let observation = FakeApplicationConditionObservation(onChange: onChange)
        observations[bundleIdentifier] = observation
        return observation
    }

    func setRunning(_ running: Bool, bundleIdentifier: String) {
        if running {
            runningBundleIdentifiers.insert(bundleIdentifier)
        } else {
            runningBundleIdentifiers.remove(bundleIdentifier)
        }
        observations[bundleIdentifier]?.send(running)
    }
}

@MainActor
private final class FakeApplicationConditionObservation: ApplicationConditionObservation {
    private var onChange: (@MainActor (Bool) -> Void)?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    func send(_ running: Bool) {
        onChange?(running)
    }

    func cancel() {
        onChange = nil
    }
}

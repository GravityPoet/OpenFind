import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Awake Notification Controller Tests")
struct AwakeNotificationControllerTests {
    @Test func notificationChannelMatchesSigningIdentity() {
        #expect(SystemAwakeNotificationDelivery.shouldUseLocalBanner(
            signingTeamIdentifier: nil
        ))
        #expect(!SystemAwakeNotificationDelivery.shouldUseLocalBanner(
            signingTeamIdentifier: "ABCDE12345"
        ))
    }

    @Test func selfSignedDeliveryUsesThePermissionlessLocalBanner() async throws {
        let presenter = FakeNotificationBannerPresenter()
        let delivery = SystemAwakeNotificationDelivery(
            bundleURL: URL(fileURLWithPath: "/tmp/OpenFindTests-missing-bundle"),
            bannerPresenter: presenter
        )
        let payload = AwakeNotificationPayload(
            identifier: "test",
            title: "Title",
            body: "Body",
            playsSound: true
        )

        #expect(try await delivery.requestAuthorization())
        try await delivery.deliver(payload)
        #expect(presenter.payloads == [payload])

        delivery.removeDeliveredNotifications()
        #expect(presenter.dismissCount == 1)
    }

    @Test func automaticStartAndEndNotificationsExcludeManualActions() async throws {
        let suite = "OpenFindTests.AwakeNotifications.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = AwakeSessionController(assertions: NotificationPowerAssertions())
        let delivery = FakeNotificationDelivery()
        let sounds = FakeSoundPlayer()
        let controller = AwakeNotificationController(
            sessions: sessions,
            defaults: defaults,
            delivery: delivery,
            soundPlayer: sounds
        )
        controller.setNotifiesAutomaticStarts(true)
        controller.setNotifiesAutomaticEnds(true)
        controller.setPlaysStartEndSounds(true)
        controller.start()
        defer { controller.stop() }

        try sessions.start(.init(source: .manual))
        try await Task.sleep(for: .milliseconds(20))
        #expect(delivery.payloads.isEmpty)

        try sessions.end()
        try sessions.start(.init(source: .applicationLaunch))
        try await waitUntil {
            delivery.payloads.contains {
                $0.identifier == AwakeNotificationController.startNotificationID
            }
        }
        #expect(delivery.payloads.contains { $0.identifier == AwakeNotificationController.startNotificationID })
        try await sessions.endAsync(reason: .deadline)
        try await waitUntil {
            delivery.payloads.contains {
                $0.identifier == AwakeNotificationController.endNotificationID
            }
        }
        #expect(delivery.payloads.contains { $0.identifier == AwakeNotificationController.endNotificationID })
        #expect(sounds.playCount == 4)
    }

    @Test func remindersFollowReplacementAndStopAfterEnd() async throws {
        let suite = "OpenFindTests.AwakeNotifications.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = AwakeSessionController(assertions: NotificationPowerAssertions())
        let delivery = FakeNotificationDelivery()
        let controller = AwakeNotificationController(
            sessions: sessions,
            defaults: defaults,
            delivery: delivery,
            soundPlayer: FakeSoundPlayer(),
            secondsPerReminderMinute: 0.01
        )
        controller.setRemindersEnabled(true)
        controller.setReminderIntervalMinutes(1)
        controller.start()
        defer { controller.stop() }

        try sessions.start(.init(source: .manual))
        try await waitUntil { delivery.payloads.contains { $0.identifier == AwakeNotificationController.reminderNotificationID } }
        let countBeforeEnd = delivery.payloads.count
        try await sessions.endAsync()
        try await Task.sleep(for: .milliseconds(40))
        #expect(delivery.payloads.count == countBeforeEnd)
    }

    @Test func closedDisplayWarningsRepeatOnlyWhileTheRealLidIsClosed() async throws {
        let suite = "OpenFindTests.AwakeNotifications.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = AwakeSessionController(
            assertions: NotificationPowerAssertions(),
            closedDisplay: NotificationClosedDisplayManager(),
            closedDisplayPowerMonitor: NotificationPowerSourceMonitor()
        )
        let delivery = FakeNotificationDelivery()
        let warningSound = FakeClosedDisplayWarningSound()
        let lid = FakeNotificationClosedDisplayStateMonitor()
        let environment = FakeClosedDisplayWarningEnvironment()
        let controller = AwakeNotificationController(
            sessions: sessions,
            defaults: defaults,
            delivery: delivery,
            soundPlayer: FakeSoundPlayer(),
            closedDisplayWarningSound: warningSound,
            closedDisplayState: lid,
            closedDisplayWarningEnvironment: environment,
            secondsPerClosedDisplayWarningMinute: 0.01
        )
        controller.setWarnsClosedDisplay(true)
        controller.setRepeatsClosedDisplayWarning(true)
        controller.setClosedDisplayWarningIntervalMinutes(1)
        controller.setAdjustsClosedDisplayWarningVolume(true)
        controller.setClosedDisplayWarningVolumePercentage(35)
        controller.start()
        defer { controller.stop() }

        try await sessions.startAsync(.init(options: .init(
            allowsDisplaySleep: false,
            allowsClosedDisplaySleep: false
        )))
        lid.emit(.closed)
        try await waitUntil { warningSound.volumes.count >= 2 }
        #expect(warningSound.volumes.allSatisfy { $0 == 35 })
        #expect(delivery.payloads.contains {
            $0.identifier == AwakeNotificationController.closedDisplayWarningNotificationID
                && !$0.playsSound
        })

        lid.emit(.open)
        let warningCount = warningSound.volumes.count
        try await Task.sleep(for: .milliseconds(40))
        #expect(warningSound.volumes.count == warningCount)
        #expect(warningSound.restoreCount > 0)
        try await sessions.endAsync()
    }

    @Test func ordinaryPoweredExternalDisplayClamshellModeSuppressesWarning() async throws {
        let suite = "OpenFindTests.AwakeNotifications.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = AwakeSessionController(
            assertions: NotificationPowerAssertions(),
            closedDisplay: NotificationClosedDisplayManager(),
            closedDisplayPowerMonitor: NotificationPowerSourceMonitor()
        )
        let delivery = FakeNotificationDelivery()
        let warningSound = FakeClosedDisplayWarningSound()
        let lid = FakeNotificationClosedDisplayStateMonitor()
        let environment = FakeClosedDisplayWarningEnvironment(suppressesWarning: true)
        let controller = AwakeNotificationController(
            sessions: sessions,
            defaults: defaults,
            delivery: delivery,
            soundPlayer: FakeSoundPlayer(),
            closedDisplayWarningSound: warningSound,
            closedDisplayState: lid,
            closedDisplayWarningEnvironment: environment,
            secondsPerClosedDisplayWarningMinute: 0.01
        )
        controller.setWarnsClosedDisplay(true)
        controller.setRepeatsClosedDisplayWarning(true)
        controller.start()
        defer { controller.stop() }

        try await sessions.startAsync(.init(options: .init(
            allowsDisplaySleep: false,
            allowsClosedDisplaySleep: false
        )))
        lid.emit(.closed)
        try await Task.sleep(for: .milliseconds(30))
        #expect(warningSound.volumes.isEmpty)
        #expect(delivery.payloads.isEmpty)

        environment.setSuppressed(false)
        try await waitUntil {
            warningSound.volumes.count == 1 && delivery.payloads.contains {
                $0.identifier == AwakeNotificationController.closedDisplayWarningNotificationID
            }
        }
        #expect(delivery.payloads.contains {
            $0.identifier == AwakeNotificationController.closedDisplayWarningNotificationID
        })

        environment.setSuppressed(true)
        let warningCount = warningSound.volumes.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(warningSound.volumes.count == warningCount)
        #expect(warningSound.restoreCount > 0)
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

private final class NotificationPowerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

@MainActor
private final class FakeNotificationBannerPresenter: AwakeNotificationBannerPresenting {
    private(set) var payloads: [AwakeNotificationPayload] = []
    private(set) var dismissCount = 0

    func present(_ payload: AwakeNotificationPayload) {
        payloads.append(payload)
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private final class FakeNotificationDelivery: AwakeNotificationDelivering {
    var authorizationResult = true
    private(set) var authorizationCount = 0
    private(set) var payloads: [AwakeNotificationPayload] = []
    private(set) var removeCount = 0

    func requestAuthorization() async throws -> Bool {
        authorizationCount += 1
        return authorizationResult
    }

    func deliver(_ payload: AwakeNotificationPayload) async throws {
        payloads.append(payload)
    }

    func removeDeliveredNotifications() {
        removeCount += 1
    }
}

@MainActor
private final class FakeSoundPlayer: SessionSoundPlaying {
    private(set) var playCount = 0

    func play() {
        playCount += 1
    }
}

@MainActor
private final class FakeClosedDisplayWarningSound: ClosedDisplayWarningSoundPlaying {
    private(set) var volumes: [Int?] = []
    private(set) var restoreCount = 0

    func play(temporaryVolumePercentage: Int?) {
        volumes.append(temporaryVolumePercentage)
    }

    func restoreVolume() {
        restoreCount += 1
    }
}

@MainActor
private final class FakeNotificationClosedDisplayStateMonitor: ClosedDisplayStateMonitoring {
    private var handler: (@MainActor (ClosedDisplayHardwareState) -> Void)?
    private var state: ClosedDisplayHardwareState = .open

    func start(handler: @escaping @MainActor (ClosedDisplayHardwareState) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func currentState() -> ClosedDisplayHardwareState { state }

    func emit(_ state: ClosedDisplayHardwareState) {
        self.state = state
        handler?(state)
    }
}

@MainActor
private final class FakeClosedDisplayWarningEnvironment: ClosedDisplayWarningEnvironmentProviding {
    private(set) var suppressesWarning: Bool
    private var handler: (@MainActor () -> Void)?

    init(suppressesWarning: Bool = false) {
        self.suppressesWarning = suppressesWarning
    }

    func start(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func setSuppressed(_ suppressed: Bool) {
        suppressesWarning = suppressed
        handler?()
    }
}

@MainActor
private final class NotificationClosedDisplayManager: ClosedDisplayModeManaging {
    var isEnabled = false
    var hasPendingRestoration: Bool { isEnabled }

    func recoverIfNeeded() async -> Bool { true }
    func enable() async throws { isEnabled = true }
    func disable() async throws { isEnabled = false }
}

@MainActor
private final class NotificationPowerSourceMonitor: PowerSourceMonitoring {
    private var handler: (@MainActor (PowerSourceSnapshot) -> Void)?
    private var current = PowerSourceSnapshot(batteryPercentage: 80, adapterConnected: true)

    func start(handler: @escaping @MainActor (PowerSourceSnapshot) -> Void) {
        self.handler = handler
        handler(current)
    }

    func stop() {
        handler = nil
    }

    func snapshot() -> PowerSourceSnapshot { current }
}

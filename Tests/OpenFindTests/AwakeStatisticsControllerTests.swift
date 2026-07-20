import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Awake Statistics Controller Tests")
struct AwakeStatisticsControllerTests {
    @Test func completedSessionPersistsCountDurationAndAverage() throws {
        let suite = "OpenFindTests.AwakeStatistics.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StatisticsClock(Date(timeIntervalSince1970: 1_000))
        let sessions = AwakeSessionController(assertions: StatisticsAssertionController())
        let statistics = AwakeStatisticsController(
            sessions: sessions,
            defaults: defaults,
            dateProvider: { clock.now }
        )

        statistics.setEnabled(true)
        try sessions.start(.init(), at: clock.now)
        clock.now = clock.now.addingTimeInterval(90)
        try sessions.end()

        #expect(statistics.sessionCount(at: clock.now) == 1)
        #expect(statistics.totalDuration(at: clock.now) == 90)
        #expect(statistics.averageSessionDuration(at: clock.now) == 90)

        let reloaded = AwakeStatisticsController(
            sessions: AwakeSessionController(assertions: StatisticsAssertionController()),
            defaults: defaults,
            dateProvider: { clock.now }
        )
        #expect(reloaded.isEnabled)
        #expect(reloaded.completedSessionCount == 1)
        #expect(reloaded.storedTotalDuration == 90)
    }

    @Test func replacementIsOneContinuousSession() throws {
        let suite = "OpenFindTests.AwakeStatistics.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StatisticsClock(Date(timeIntervalSince1970: 2_000))
        let sessions = AwakeSessionController(assertions: StatisticsAssertionController())
        let statistics = AwakeStatisticsController(
            sessions: sessions,
            defaults: defaults,
            dateProvider: { clock.now }
        )
        statistics.setEnabled(true)

        try sessions.start(.init(), at: clock.now)
        clock.now = clock.now.addingTimeInterval(30)
        try sessions.start(.init(endCondition: .after(60)), at: clock.now)
        clock.now = clock.now.addingTimeInterval(30)
        try sessions.end()

        #expect(statistics.completedSessionCount == 1)
        #expect(statistics.storedTotalDuration == 60)
    }

    @Test func disablingAndResettingCommitOnlyTheObservedInterval() throws {
        let suite = "OpenFindTests.AwakeStatistics.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = StatisticsClock(Date(timeIntervalSince1970: 3_000))
        let sessions = AwakeSessionController(assertions: StatisticsAssertionController())
        let statistics = AwakeStatisticsController(
            sessions: sessions,
            defaults: defaults,
            dateProvider: { clock.now }
        )
        try sessions.start(.init(), at: clock.now)

        statistics.setEnabled(true)
        clock.now = clock.now.addingTimeInterval(20)
        statistics.setEnabled(false)
        #expect(statistics.storedTotalDuration == 20)
        #expect(statistics.completedSessionCount == 1)

        statistics.setEnabled(true)
        statistics.reset()
        #expect(statistics.storedTotalDuration == 0)
        #expect(statistics.completedSessionCount == 0)
        clock.now = clock.now.addingTimeInterval(5)
        #expect(statistics.totalDuration(at: clock.now) == 5)
        #expect(statistics.sessionCount(at: clock.now) == 1)
    }
}

@MainActor
private final class StatisticsClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class StatisticsAssertionController: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

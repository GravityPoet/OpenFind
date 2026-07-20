import Foundation
import Observation

@MainActor
@Observable
final class AwakeStatisticsController {
    private static let enabledKey = "OpenFind.awakeStatistics.enabledV1"
    private static let totalDurationKey = "OpenFind.awakeStatistics.totalDurationV1"
    private static let completedSessionCountKey = "OpenFind.awakeStatistics.sessionCountV1"

    @ObservationIgnored private let sessions: AwakeSessionController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dateProvider: @MainActor () -> Date
    @ObservationIgnored private var subscription: AwakeSessionEventSubscription?
    @ObservationIgnored private var activeStartedAt: Date?

    private(set) var isEnabled: Bool
    private(set) var storedTotalDuration: TimeInterval
    private(set) var completedSessionCount: Int

    init(
        sessions: AwakeSessionController,
        defaults: UserDefaults = .standard,
        dateProvider: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.sessions = sessions
        self.defaults = defaults
        self.dateProvider = dateProvider
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedDuration = defaults.double(forKey: Self.totalDurationKey)
        storedTotalDuration = storedDuration.isFinite ? max(0, storedDuration) : 0
        completedSessionCount = max(0, defaults.integer(
            forKey: Self.completedSessionCountKey
        ))
        if isEnabled, let session = sessions.activeSession {
            activeStartedAt = session.startedAt
        }
        subscription = sessions.observeEvents { [weak self] event in
            self?.handle(event)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        let now = dateProvider()
        if enabled {
            isEnabled = true
            activeStartedAt = sessions.isActive ? now : nil
        } else {
            recordActiveSession(endedAt: now)
            isEnabled = false
        }
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func reset() {
        storedTotalDuration = 0
        completedSessionCount = 0
        activeStartedAt = isEnabled && sessions.isActive ? dateProvider() : nil
        persistTotals()
    }

    func totalDuration(at date: Date) -> TimeInterval {
        guard isEnabled, let activeStartedAt else { return storedTotalDuration }
        return storedTotalDuration + max(0, date.timeIntervalSince(activeStartedAt))
    }

    func sessionCount(at date: Date) -> Int {
        guard isEnabled, activeStartedAt != nil else { return completedSessionCount }
        return completedSessionCount + 1
    }

    func averageSessionDuration(at date: Date) -> TimeInterval {
        let count = sessionCount(at: date)
        guard count > 0 else { return 0 }
        return totalDuration(at: date) / TimeInterval(count)
    }

    private func handle(_ event: AwakeSessionEvent) {
        guard isEnabled else { return }
        switch event {
        case let .started(session):
            activeStartedAt = session.startedAt
        case let .replaced(previous, _):
            if activeStartedAt == nil { activeStartedAt = previous.startedAt }
        case .updated:
            break
        case .ended:
            recordActiveSession(endedAt: dateProvider())
        }
    }

    private func recordActiveSession(endedAt: Date) {
        guard let activeStartedAt else { return }
        let duration = max(0, endedAt.timeIntervalSince(activeStartedAt))
        if duration.isFinite {
            storedTotalDuration += duration
            completedSessionCount += 1
            persistTotals()
        }
        self.activeStartedAt = nil
    }

    private func persistTotals() {
        defaults.set(storedTotalDuration, forKey: Self.totalDurationKey)
        defaults.set(completedSessionCount, forKey: Self.completedSessionCountKey)
    }
}

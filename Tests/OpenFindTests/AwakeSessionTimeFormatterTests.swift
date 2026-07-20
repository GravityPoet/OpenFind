import Foundation
import Testing
@testable import OpenFind

@Suite("Awake Session Time Formatter Tests")
struct AwakeSessionTimeFormatterTests {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    @Test func remainingTimeSupportsMinutesAndOptionalSeconds() {
        let session = timedSession()

        #expect(text(session, remaining: 3_660, style: .remaining) == "1:01")
        #expect(text(
            session,
            remaining: 3_660,
            style: .remaining,
            includesSeconds: true
        ) == "1:01:00")
        #expect(text(session, remaining: 61, style: .remaining) == "0:02")
    }

    @Test func timerEndTimeTracksTheCurrentClockProjection() {
        let session = timedSession(calculation: .timer)
        let now = Date(timeIntervalSince1970: 15 * 3_600)

        #expect(text(
            session,
            remaining: 30 * 60,
            now: now,
            style: .endTime,
            uses24HourClock: true
        ) == "15:30")
    }

    @Test func systemClockEndTimeUsesTheStoredWallClockDeadline() {
        let start = Date(timeIntervalSince1970: 13 * 3_600)
        let session = timedSession(start: start, calculation: .systemClock)

        #expect(text(
            session,
            remaining: 30 * 60,
            now: start.addingTimeInterval(30 * 60),
            style: .endTime,
            uses24HourClock: true
        ) == "14:00")
        #expect(text(
            session,
            remaining: 30 * 60,
            now: start,
            style: .endTime,
            includesSeconds: true
        ) == "2:00:00 PM")
    }

    @Test func untimedSessionsDoNotProduceTimeText() {
        let session = AwakeSession(
            id: UUID(),
            startedAt: Date(),
            endCondition: .indefinitely,
            options: .defaultValue,
            source: .manual
        )

        #expect(text(session, remaining: nil, style: .remaining) == nil)
        #expect(text(session, remaining: nil, style: .endTime) == nil)
    }

    private func timedSession(
        start: Date = Date(timeIntervalSince1970: 13 * 3_600),
        calculation: AwakeEndTimeCalculation = .timer
    ) -> AwakeSession {
        AwakeSession(
            id: UUID(),
            startedAt: start,
            endCondition: .after(60 * 60),
            options: .init(
                allowsDisplaySleep: false,
                endTimeCalculation: calculation
            ),
            source: .manual
        )
    }

    private func text(
        _ session: AwakeSession,
        remaining: TimeInterval?,
        now: Date = Date(timeIntervalSince1970: 13 * 3_600),
        style: AwakeMenuBarTimeStyle,
        uses24HourClock: Bool = false,
        includesSeconds: Bool = false
    ) -> String? {
        AwakeSessionTimeFormatter.text(
            session: session,
            remainingTime: remaining,
            now: now,
            style: style,
            uses24HourClock: uses24HourClock,
            includesSeconds: includesSeconds,
            locale: locale,
            timeZone: timeZone
        )
    }
}

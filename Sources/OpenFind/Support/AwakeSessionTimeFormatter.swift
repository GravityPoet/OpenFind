import Foundation

enum AwakeSessionTimeFormatter {
    static func text(
        session: AwakeSession,
        remainingTime: TimeInterval?,
        now: Date,
        style: AwakeMenuBarTimeStyle,
        uses24HourClock: Bool,
        includesSeconds: Bool,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let remainingTime,
              remainingTime.isFinite else { return nil }

        switch style {
        case .remaining:
            return durationText(
                remainingTime,
                includesSeconds: includesSeconds
            )
        case .endTime:
            let endDate: Date?
            if case .after = session.endCondition,
               session.options.endTimeCalculation == .timer {
                endDate = now.addingTimeInterval(max(0, remainingTime))
            } else {
                endDate = session.deadline
            }
            guard let endDate else { return nil }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            if uses24HourClock {
                formatter.dateFormat = includesSeconds ? "HH:mm:ss" : "HH:mm"
            } else {
                formatter.dateFormat = includesSeconds ? "h:mm:ss a" : "h:mm a"
            }
            return formatter.string(from: endDate)
        }
    }

    private static func durationText(
        _ remainingTime: TimeInterval,
        includesSeconds: Bool
    ) -> String? {
        let clamped = max(0, remainingTime)
        if includesSeconds {
            let rounded = ceil(clamped)
            guard rounded <= Double(Int.max) else { return nil }
            let totalSeconds = Int(rounded)
            let hours = totalSeconds / 3_600
            let minutes = totalSeconds % 3_600 / 60
            let seconds = totalSeconds % 60
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        let rounded = ceil(clamped / 60)
        guard rounded <= Double(Int.max) else { return nil }
        let totalMinutes = Int(rounded)
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

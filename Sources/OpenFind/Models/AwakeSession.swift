import Foundation

enum AwakeSessionEndCondition: Equatable, Sendable {
    case indefinitely
    case after(TimeInterval)
    case at(Date)
    case whileApplicationRuns(bundleIdentifier: String)
    case whileFileDownloads(URL, inactivityTimeout: TimeInterval)

    func validated(at now: Date) throws -> Self {
        switch self {
        case .indefinitely:
            return self
        case let .after(seconds):
            guard seconds.isFinite, seconds > 0 else {
                throw AwakeSessionValidationError.invalidDuration
            }
            return self
        case let .at(date):
            guard date.timeIntervalSince(now).isFinite, date > now else {
                throw AwakeSessionValidationError.invalidEndDate
            }
            return self
        case let .whileApplicationRuns(bundleIdentifier):
            let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.count <= 512,
                  normalized.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw AwakeSessionValidationError.invalidBundleIdentifier
            }
            return .whileApplicationRuns(bundleIdentifier: normalized)
        case let .whileFileDownloads(url, inactivityTimeout):
            guard url.isFileURL,
                  !url.path.isEmpty,
                  url.path.utf8.count <= 4_096,
                  inactivityTimeout.isFinite,
                  inactivityTimeout > 0,
                  inactivityTimeout <= 24 * 60 * 60 else {
                throw AwakeSessionValidationError.invalidFileURL
            }
            return .whileFileDownloads(
                url.standardizedFileURL,
                inactivityTimeout: inactivityTimeout
            )
        }
    }

    func deadline(startedAt: Date) -> Date? {
        switch self {
        case .indefinitely, .whileApplicationRuns, .whileFileDownloads:
            return nil
        case let .after(seconds):
            return startedAt.addingTimeInterval(seconds)
        case let .at(date):
            return date
        }
    }
}

enum AwakeSessionSource: Equatable, Sendable {
    case manual
    case trigger(UUID)
    case appleScript
    case applicationLaunch
    case wake
    case powerAdapter
}

enum AwakeSessionEndReason: Equatable, Sendable {
    case requested
    case deadline
    case condition
    case triggerCondition
    case forcedSleep
    case sessionResign
    case lowBattery
    case closedDisplayPowerChange
    case applicationTermination
}

enum AwakeSessionEvent: Equatable, Sendable {
    case started(AwakeSession)
    case replaced(previous: AwakeSession, current: AwakeSession)
    case updated(AwakeSession)
    case ended(AwakeSession, reason: AwakeSessionEndReason)
}

enum ScreenSaverPolicy: Equatable, Codable, Sendable {
    case prevent
    case allow(after: TimeInterval)
}

enum AwakeEndTimeCalculation: String, CaseIterable, Codable, Sendable {
    case timer
    case systemClock
}

struct AwakeSessionOptions: Equatable, Codable, Sendable {
    var allowsDisplaySleep: Bool
    var screenSaverPolicy: ScreenSaverPolicy
    var screenSaverExceptionIdentifiers: Set<String>
    var allowsClosedDisplaySleep: Bool
    var endTimeCalculation: AwakeEndTimeCalculation

    init(
        allowsDisplaySleep: Bool,
        screenSaverPolicy: ScreenSaverPolicy = .prevent,
        screenSaverExceptionIdentifiers: Set<String> = [],
        allowsClosedDisplaySleep: Bool = true,
        endTimeCalculation: AwakeEndTimeCalculation = .timer
    ) {
        self.allowsDisplaySleep = allowsDisplaySleep
        self.screenSaverPolicy = screenSaverPolicy
        self.screenSaverExceptionIdentifiers = screenSaverExceptionIdentifiers
        self.allowsClosedDisplaySleep = allowsClosedDisplaySleep
        self.endTimeCalculation = endTimeCalculation
    }

    func validated() throws -> Self {
        if case let .allow(after) = screenSaverPolicy,
           (!after.isFinite || after < 0) {
            throw AwakeSessionValidationError.invalidScreenSaverDelay
        }
        guard screenSaverExceptionIdentifiers.count <= 128,
              screenSaverExceptionIdentifiers.allSatisfy({ identifier in
                  let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !normalized.isEmpty
                      && normalized.utf8.count <= 512
                      && normalized.unicodeScalars.allSatisfy {
                          !CharacterSet.controlCharacters.contains($0)
                      }
              }) else {
            throw AwakeSessionValidationError.invalidScreenSaverException
        }
        var normalized = self
        normalized.screenSaverExceptionIdentifiers = Set(
            screenSaverExceptionIdentifiers.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case allowsDisplaySleep
        case screenSaverPolicy
        case screenSaverExceptionIdentifiers
        case allowsClosedDisplaySleep
        case endTimeCalculation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsDisplaySleep = try container.decode(Bool.self, forKey: .allowsDisplaySleep)
        screenSaverPolicy = try container.decodeIfPresent(
            ScreenSaverPolicy.self,
            forKey: .screenSaverPolicy
        ) ?? .prevent
        screenSaverExceptionIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .screenSaverExceptionIdentifiers
        ) ?? []
        allowsClosedDisplaySleep = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsClosedDisplaySleep
        ) ?? true
        endTimeCalculation = try container.decodeIfPresent(
            AwakeEndTimeCalculation.self,
            forKey: .endTimeCalculation
        ) ?? .timer
    }

    static let defaultValue = AwakeSessionOptions(allowsDisplaySleep: false)
}

struct AwakeSessionRequest: Equatable, Sendable {
    var endCondition: AwakeSessionEndCondition
    var options: AwakeSessionOptions
    var source: AwakeSessionSource

    init(
        endCondition: AwakeSessionEndCondition = .indefinitely,
        options: AwakeSessionOptions = .defaultValue,
        source: AwakeSessionSource = .manual
    ) {
        self.endCondition = endCondition
        self.options = options
        self.source = source
    }
}

struct AwakeSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var endCondition: AwakeSessionEndCondition
    var options: AwakeSessionOptions
    let source: AwakeSessionSource

    func remainingTime(at date: Date) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(date)) }
    }

    var deadline: Date? {
        endCondition.deadline(startedAt: startedAt)
    }
}

enum AwakeSessionValidationError: Error, Equatable, LocalizedError {
    case invalidDuration
    case invalidEndDate
    case invalidBundleIdentifier
    case invalidFileURL
    case invalidScreenSaverDelay
    case invalidScreenSaverException
    case conditionMonitorUnavailable
    case conditionNotMet
    case sessionCannotBeExtended
    case closedDisplayRequiresAsync
    case powerTransitionInProgress

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "The awake session duration must be finite and greater than zero."
        case .invalidEndDate:
            return "The awake session end date must be in the future."
        case .invalidBundleIdentifier:
            return "The application bundle identifier is invalid."
        case .invalidFileURL:
            return "The download target must be a valid local file URL."
        case .invalidScreenSaverDelay:
            return "The screen-saver delay must be finite and nonnegative."
        case .invalidScreenSaverException:
            return "A screen-saver exception identifier is invalid."
        case .conditionMonitorUnavailable:
            return "This session condition requires a lifecycle monitor."
        case .conditionNotMet:
            return "The selected condition is not currently active."
        case .sessionCannotBeExtended:
            return "Only an active timed awake session can be extended."
        case .closedDisplayRequiresAsync:
            return "Closed-display power changes require the asynchronous session API."
        case .powerTransitionInProgress:
            return "Another awake-session power transition is still in progress."
        }
    }
}

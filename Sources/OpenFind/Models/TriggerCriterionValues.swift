import Foundation

enum TriggerWeekday: Int, CaseIterable, Codable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

struct ScheduleCriterion: Equatable, Codable, Sendable {
    var weekdays: Set<TriggerWeekday>
    var startMinute: Int
    var endMinute: Int
}

enum ThresholdOperator: String, Codable, Sendable {
    case lessThan
    case greaterThan
}

struct ThresholdCriterion: Equatable, Codable, Sendable {
    var comparison: ThresholdOperator
    var value: Double
}

enum IPAddressCriterion: Equatable, Codable, Sendable {
    case exact(IPAddress)
    case range(start: IPAddress, end: IPAddress)
}

struct ApplicationCriterion: Equatable, Codable, Sendable {
    var identifier: String
    var requiresFrontmost: Bool
}

enum CountOperator: String, Codable, Sendable {
    case lessThan
    case equal
    case greaterThan
}

enum DisplayRequirement: Equatable, Codable, Sendable {
    case count(comparison: CountOperator, value: Int)
    case mainDisplayMirrored
}

struct DisplayCriterion: Equatable, Codable, Sendable {
    var requirement: DisplayRequirement
    var ignoresBuiltInDisplay: Bool
}

enum AudioOutputTarget: Equatable, Codable, Sendable {
    case device(identifier: String)
    case builtInOutput
    case builtInSpeakers
    case wiredHeadphones
}

enum PowerAdapterRequirement: String, Codable, Sendable {
    case connected
    case disconnected
}

enum LogicalOperator: String, Codable, Sendable {
    case and
    case or
}

struct BatteryPowerCriterion: Equatable, Codable, Sendable {
    var minimumBatteryPercentage: Double?
    var powerAdapter: PowerAdapterRequirement?
    var combination: LogicalOperator
}

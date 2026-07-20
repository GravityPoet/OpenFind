import Foundation

enum AudioOutputKind: String, Codable, Sendable {
    case other
    case builtInOutput
    case builtInSpeakers
    case wiredHeadphones
}

struct TriggerSnapshot: Equatable, Sendable {
    var date: Date = Date()
    var systemIdleTime: TimeInterval? = nil
    var dnsServers: Set<IPAddress> = []
    var wifiSSID: String? = nil
    var ipAddresses: Set<IPAddress> = []
    var activeVPNServices: Set<String> = []
    var mountedVolumeIdentifiers: Set<String> = []
    var runningApplicationIdentifiers: Set<String> = []
    var frontmostApplicationIdentifier: String? = nil
    var frontmostApplicationIdentifiers: Set<String> = []
    var cpuUtilizationPercentage: Double? = nil
    var displayCount: Int? = nil
    var builtInDisplayCount: Int = 0
    var isMainDisplayMirrored: Bool? = nil
    var connectedBluetoothIdentifiers: Set<String> = []
    var audioOutputIdentifier: String? = nil
    var audioOutputKind: AudioOutputKind? = nil
    var connectedUSBIdentifiers: Set<String> = []
    var batteryPercentage: Double? = nil
    var powerAdapterConnected: Bool? = nil
}

struct TriggerEvaluation: Equatable, Sendable {
    var failedCriteria: Set<TriggerCriterion.Kind>
    var unavailableCriteria: Set<TriggerCriterion.Kind>

    var isMatch: Bool {
        failedCriteria.isEmpty && unavailableCriteria.isEmpty
    }
}

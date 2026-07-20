import Foundation

enum TriggerCriterion: Equatable, Codable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case schedule
        case systemIdleTime
        case dnsServer
        case wifiNetwork
        case ipAddress
        case ciscoAnyConnectVPN
        case volume
        case application
        case cpuUtilization
        case displays
        case bluetoothDevice
        case audioOutput
        case usbDevice
        case batteryAndPowerAdapter
    }

    case schedule(ScheduleCriterion)
    case systemIdleTime(ThresholdCriterion)
    case dnsServer(Set<IPAddress>)
    case wifiNetwork(String)
    case ipAddress(IPAddressCriterion)
    case ciscoAnyConnectVPN(String)
    case volume(identifier: String)
    case application(ApplicationCriterion)
    case cpuUtilization(ThresholdCriterion)
    case displays(DisplayCriterion)
    case bluetoothDevice(identifier: String)
    case audioOutput(AudioOutputTarget)
    case usbDevice(identifier: String)
    case batteryAndPowerAdapter(BatteryPowerCriterion)

    var kind: Kind {
        switch self {
        case .schedule: .schedule
        case .systemIdleTime: .systemIdleTime
        case .dnsServer: .dnsServer
        case .wifiNetwork: .wifiNetwork
        case .ipAddress: .ipAddress
        case .ciscoAnyConnectVPN: .ciscoAnyConnectVPN
        case .volume: .volume
        case .application: .application
        case .cpuUtilization: .cpuUtilization
        case .displays: .displays
        case .bluetoothDevice: .bluetoothDevice
        case .audioOutput: .audioOutput
        case .usbDevice: .usbDevice
        case .batteryAndPowerAdapter: .batteryAndPowerAdapter
        }
    }

    func validated() throws -> Self {
        switch self {
        case let .schedule(value):
            guard !value.weekdays.isEmpty,
                  (0...1_439).contains(value.startMinute),
                  (0...1_439).contains(value.endMinute) else {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        case let .systemIdleTime(value):
            try validateThreshold(value, allowZero: false)
        case let .dnsServer(addresses):
            guard !addresses.isEmpty else { throw AwakeTriggerValidationError.invalidCriterion(kind) }
        case let .wifiNetwork(ssid):
            guard isValidIdentifier(ssid, maximumUTF8Length: 32) else {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        case let .ipAddress(value):
            if case let .range(start, end) = value {
                guard start.family == end.family, start <= end else {
                    throw AwakeTriggerValidationError.invalidCriterion(kind)
                }
            }
        case let .ciscoAnyConnectVPN(service),
             let .volume(identifier: service),
             let .bluetoothDevice(identifier: service),
             let .usbDevice(identifier: service):
            guard isValidIdentifier(service) else {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        case let .application(value):
            guard isValidIdentifier(value.identifier) else {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        case let .cpuUtilization(value):
            try validateThreshold(value, allowZero: true)
            guard value.value <= 100 else { throw AwakeTriggerValidationError.invalidCriterion(kind) }
        case let .displays(value):
            if case let .count(_, count) = value.requirement, count < 0 {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        case let .audioOutput(value):
            if case let .device(identifier) = value, !isValidIdentifier(identifier) {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        case let .batteryAndPowerAdapter(value):
            guard value.minimumBatteryPercentage != nil || value.powerAdapter != nil else {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
            if let percentage = value.minimumBatteryPercentage,
               !percentage.isFinite || !(0...100).contains(percentage) {
                throw AwakeTriggerValidationError.invalidCriterion(kind)
            }
        }
        return self
    }

    private func validateThreshold(
        _ value: ThresholdCriterion,
        allowZero: Bool
    ) throws {
        let validRange = allowZero ? value.value >= 0 : value.value > 0
        guard value.value.isFinite, validRange else {
            throw AwakeTriggerValidationError.invalidCriterion(kind)
        }
    }

    private func isValidIdentifier(_ value: String, maximumUTF8Length: Int = 1_024) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.utf8.count <= maximumUTF8Length
            && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

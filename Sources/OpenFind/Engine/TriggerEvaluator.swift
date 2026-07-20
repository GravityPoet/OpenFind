import Foundation

struct TriggerEvaluator {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func evaluate(_ trigger: AwakeTrigger, snapshot: TriggerSnapshot) -> TriggerEvaluation {
        var failed: Set<TriggerCriterion.Kind> = []
        var unavailable: Set<TriggerCriterion.Kind> = []
        for criterion in trigger.criteria {
            switch evaluate(criterion, snapshot: snapshot) {
            case true:
                break
            case false:
                failed.insert(criterion.kind)
            case nil:
                unavailable.insert(criterion.kind)
            }
        }
        return TriggerEvaluation(failedCriteria: failed, unavailableCriteria: unavailable)
    }

    func firstMatching(
        in triggers: [AwakeTrigger],
        snapshot: TriggerSnapshot
    ) -> AwakeTrigger? {
        triggers.first { trigger in
            trigger.isEnabled && evaluate(trigger, snapshot: snapshot).isMatch
        }
    }

    private func evaluate(
        _ criterion: TriggerCriterion,
        snapshot: TriggerSnapshot
    ) -> Bool? {
        switch criterion {
        case let .schedule(schedule):
            return evaluate(schedule, at: snapshot.date)
        case let .systemIdleTime(threshold):
            // Amphetamine exposes this criterion in minutes; the HID clock is
            // sampled in seconds, so normalize at the evaluator boundary.
            return snapshot.systemIdleTime.map { compare($0 / 60, with: threshold) }
        case let .dnsServer(configured):
            return !configured.isDisjoint(with: snapshot.dnsServers)
        case let .wifiNetwork(ssid):
            return snapshot.wifiSSID.map { $0 == ssid }
        case let .ipAddress(address):
            return evaluate(address, current: snapshot.ipAddresses)
        case let .ciscoAnyConnectVPN(service):
            return snapshot.activeVPNServices.contains(service)
        case let .volume(identifier):
            return snapshot.mountedVolumeIdentifiers.contains(identifier)
        case let .application(application):
            guard snapshot.runningApplicationIdentifiers.contains(application.identifier) else {
                return false
            }
            guard application.requiresFrontmost else { return true }
            var frontmost = snapshot.frontmostApplicationIdentifiers
            if let identifier = snapshot.frontmostApplicationIdentifier {
                frontmost.insert(identifier)
            }
            return frontmost.contains(application.identifier)
        case let .cpuUtilization(threshold):
            return snapshot.cpuUtilizationPercentage.map { compare($0, with: threshold) }
        case let .displays(display):
            return evaluate(display, snapshot: snapshot)
        case let .bluetoothDevice(identifier):
            return snapshot.connectedBluetoothIdentifiers.contains(identifier)
        case let .audioOutput(target):
            return evaluate(target, snapshot: snapshot)
        case let .usbDevice(identifier):
            return snapshot.connectedUSBIdentifiers.contains(identifier)
        case let .batteryAndPowerAdapter(power):
            return evaluate(power, snapshot: snapshot)
        }
    }

    private func evaluate(_ schedule: ScheduleCriterion, at date: Date) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let rawWeekday = components.weekday,
              let weekday = TriggerWeekday(rawValue: rawWeekday),
              let hour = components.hour,
              let minute = components.minute else { return false }
        let minuteOfDay = hour * 60 + minute

        if schedule.startMinute == schedule.endMinute {
            return schedule.weekdays.contains(weekday)
        }
        if schedule.startMinute < schedule.endMinute {
            return schedule.weekdays.contains(weekday)
                && minuteOfDay >= schedule.startMinute
                && minuteOfDay < schedule.endMinute
        }
        if minuteOfDay >= schedule.startMinute {
            return schedule.weekdays.contains(weekday)
        }
        guard minuteOfDay < schedule.endMinute,
              let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return false }
        let previousRawWeekday = calendar.component(.weekday, from: yesterday)
        return TriggerWeekday(rawValue: previousRawWeekday).map(schedule.weekdays.contains) == true
    }

    private func evaluate(_ criterion: IPAddressCriterion, current: Set<IPAddress>) -> Bool {
        switch criterion {
        case let .exact(address):
            return current.contains(address)
        case let .range(start, end):
            return current.contains { address in
                address.family == start.family && address >= start && address <= end
            }
        }
    }

    private func evaluate(_ criterion: DisplayCriterion, snapshot: TriggerSnapshot) -> Bool? {
        switch criterion.requirement {
        case .mainDisplayMirrored:
            return snapshot.isMainDisplayMirrored
        case let .count(comparison, value):
            guard let displayCount = snapshot.displayCount else { return nil }
            let count = criterion.ignoresBuiltInDisplay
                ? max(0, displayCount - snapshot.builtInDisplayCount)
                : displayCount
            return compare(count, comparison: comparison, value: value)
        }
    }

    private func evaluate(_ target: AudioOutputTarget, snapshot: TriggerSnapshot) -> Bool? {
        switch target {
        case let .device(identifier):
            return snapshot.audioOutputIdentifier == identifier
        case .builtInOutput:
            return snapshot.audioOutputKind.map { $0 == .builtInOutput }
        case .builtInSpeakers:
            return snapshot.audioOutputKind.map { $0 == .builtInSpeakers }
        case .wiredHeadphones:
            return snapshot.audioOutputKind.map { $0 == .wiredHeadphones }
        }
    }

    private func evaluate(
        _ criterion: BatteryPowerCriterion,
        snapshot: TriggerSnapshot
    ) -> Bool? {
        var values: [Bool] = []
        if let minimum = criterion.minimumBatteryPercentage {
            guard let battery = snapshot.batteryPercentage else { return nil }
            values.append(battery >= minimum)
        }
        if let adapter = criterion.powerAdapter {
            guard let connected = snapshot.powerAdapterConnected else { return nil }
            values.append(adapter == .connected ? connected : !connected)
        }
        guard !values.isEmpty else { return nil }
        return criterion.combination == .and
            ? values.allSatisfy { $0 }
            : values.contains(true)
    }

    private func compare(_ current: Double, with threshold: ThresholdCriterion) -> Bool {
        threshold.comparison == .lessThan
            ? current < threshold.value
            : current > threshold.value
    }

    private func compare(_ current: Int, comparison: CountOperator, value: Int) -> Bool {
        switch comparison {
        case .lessThan: current < value
        case .equal: current == value
        case .greaterThan: current > value
        }
    }
}

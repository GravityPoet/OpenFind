import Foundation
import Testing
@testable import OpenFind

@Suite("Trigger Evaluator Tests")
struct TriggerEvaluatorTests {
    @Test func inventoryContainsAllFourteenAmphetamineCriteria() {
        #expect(TriggerCriterion.Kind.allCases.count == 14)
        #expect(Set(TriggerCriterion.Kind.allCases) == [
            .schedule, .systemIdleTime, .dnsServer, .wifiNetwork, .ipAddress,
            .ciscoAnyConnectVPN, .volume, .application, .cpuUtilization, .displays,
            .bluetoothDevice, .audioOutput, .usbDevice, .batteryAndPowerAdapter,
        ])
    }

    @Test func everyCriterionMustMatch() throws {
        let dns = try #require(IPAddress("1.1.1.1"))
        let trigger = AwakeTrigger(name: "Network", criteria: [
            .dnsServer([dns]),
            .wifiNetwork("Studio"),
        ])
        let snapshot = TriggerSnapshot(dnsServers: [dns], wifiSSID: "Elsewhere")

        let result = TriggerEvaluator().evaluate(trigger, snapshot: snapshot)

        #expect(!result.isMatch)
        #expect(result.failedCriteria == [.wifiNetwork])
        #expect(result.unavailableCriteria.isEmpty)
    }

    @Test func firstEnabledMatchingTriggerWinsInListOrder() {
        let first = AwakeTrigger(name: "First", criteria: [.wifiNetwork("Studio")])
        let second = AwakeTrigger(name: "Second", criteria: [.wifiNetwork("Studio")])
        let disabled = AwakeTrigger(
            name: "Disabled",
            isEnabled: false,
            criteria: [.wifiNetwork("Studio")]
        )
        let snapshot = TriggerSnapshot(wifiSSID: "Studio")

        let match = TriggerEvaluator().firstMatching(
            in: [disabled, first, second],
            snapshot: snapshot
        )

        #expect(match?.id == first.id)
    }

    @Test func unavailableWiFiNameDoesNotBecomeAFalseNegative() {
        let trigger = AwakeTrigger(name: "Wi-Fi", criteria: [.wifiNetwork("Studio")])

        let result = TriggerEvaluator().evaluate(trigger, snapshot: .init(wifiSSID: nil))

        #expect(!result.isMatch)
        #expect(result.failedCriteria.isEmpty)
        #expect(result.unavailableCriteria == [.wifiNetwork])
    }

    @Test func systemIdleCriterionUsesMinutesLikeTheEditor() {
        let trigger = AwakeTrigger(name: "Idle", criteria: [
            .systemIdleTime(.init(comparison: .greaterThan, value: 10)),
        ])

        #expect(TriggerEvaluator().evaluate(
            trigger,
            snapshot: .init(systemIdleTime: 10 * 60 + 1)
        ).isMatch)
        #expect(!TriggerEvaluator().evaluate(
            trigger,
            snapshot: .init(systemIdleTime: 9 * 60)
        ).isMatch)
    }

    @Test func scheduleAcrossMidnightUsesThePreviousSelectedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let criterion = ScheduleCriterion(
            weekdays: [.monday],
            startMinute: 22 * 60,
            endMinute: 2 * 60
        )
        let trigger = AwakeTrigger(name: "Overnight", criteria: [.schedule(criterion)])
        let evaluator = TriggerEvaluator(calendar: calendar)

        #expect(evaluator.evaluate(trigger, snapshot: .init(date: date(2026, 7, 20, 23, calendar))).isMatch)
        #expect(evaluator.evaluate(trigger, snapshot: .init(date: date(2026, 7, 21, 1, calendar))).isMatch)
        #expect(!evaluator.evaluate(trigger, snapshot: .init(date: date(2026, 7, 21, 3, calendar))).isMatch)
    }

    @Test func exactAndRangeIPCriteriaSupportIPv4AndIPv6() throws {
        let ipv4Start = try #require(IPAddress("192.168.1.10"))
        let ipv4End = try #require(IPAddress("192.168.1.20"))
        let ipv6 = try #require(IPAddress("2001:db8::5"))
        let snapshot = TriggerSnapshot(ipAddresses: [try #require(IPAddress("192.168.1.15")), ipv6])

        let range = AwakeTrigger(
            name: "IPv4 Range",
            criteria: [.ipAddress(.range(start: ipv4Start, end: ipv4End))]
        )
        let exact = AwakeTrigger(name: "IPv6", criteria: [.ipAddress(.exact(ipv6))])

        #expect(TriggerEvaluator().evaluate(range, snapshot: snapshot).isMatch)
        #expect(TriggerEvaluator().evaluate(exact, snapshot: snapshot).isMatch)
        #expect(ipv6.description == "2001:db8::5")
    }

    @Test func applicationDisplayAndAudioDetailsAreRespected() {
        let trigger = AwakeTrigger(name: "Desk", criteria: [
            .application(.init(identifier: "com.apple.TextEdit", requiresFrontmost: true)),
            .displays(.init(
                requirement: .count(comparison: .equal, value: 1),
                ignoresBuiltInDisplay: true
            )),
            .audioOutput(.wiredHeadphones),
        ])
        let snapshot = TriggerSnapshot(
            runningApplicationIdentifiers: ["com.apple.TextEdit"],
            frontmostApplicationIdentifier: "com.apple.TextEdit",
            displayCount: 2,
            builtInDisplayCount: 1,
            audioOutputKind: .wiredHeadphones
        )

        #expect(TriggerEvaluator().evaluate(trigger, snapshot: snapshot).isMatch)
    }

    @Test func frontmostApplicationAcceptsProcessAndLocalizedNameAliases() {
        let trigger = AwakeTrigger(name: "Helper", criteria: [
            .application(.init(identifier: "background-helper", requiresFrontmost: true)),
        ])
        let snapshot = TriggerSnapshot(
            runningApplicationIdentifiers: ["background-helper"],
            frontmostApplicationIdentifier: "com.example.Host",
            frontmostApplicationIdentifiers: ["Host", "background-helper"]
        )

        #expect(TriggerEvaluator().evaluate(trigger, snapshot: snapshot).isMatch)
    }

    @Test func batteryAndPowerAdapterSupportsAndOrSemantics() {
        let andTrigger = AwakeTrigger(name: "AND", criteria: [
            .batteryAndPowerAdapter(.init(
                minimumBatteryPercentage: 80,
                powerAdapter: .connected,
                combination: .and
            )),
        ])
        let orTrigger = AwakeTrigger(name: "OR", criteria: [
            .batteryAndPowerAdapter(.init(
                minimumBatteryPercentage: 80,
                powerAdapter: .connected,
                combination: .or
            )),
        ])
        let snapshot = TriggerSnapshot(batteryPercentage: 50, powerAdapterConnected: true)

        #expect(!TriggerEvaluator().evaluate(andTrigger, snapshot: snapshot).isMatch)
        #expect(TriggerEvaluator().evaluate(orTrigger, snapshot: snapshot).isMatch)
    }

    @Test func validatedTriggerRoundTripsAllCriterionTypes() throws {
        let ipv4 = try #require(IPAddress("10.0.0.1"))
        let trigger = try allCriteriaTrigger(ipv4: ipv4).validated()
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(AwakeTrigger.self, from: data)

        #expect(decoded == trigger)
        #expect(decoded.criteria.map(\.kind).count == 14)
    }

    @Test func duplicateCriterionTypesAreRejected() {
        let trigger = AwakeTrigger(name: "Duplicate", criteria: [
            .wifiNetwork("One"),
            .wifiNetwork("Two"),
        ])
        #expect(throws: AwakeTriggerValidationError.duplicateCriterion) {
            try trigger.validated()
        }
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ calendar: Calendar
    ) -> Date {
        calendar.date(from: .init(year: year, month: month, day: day, hour: hour))!
    }

    private func allCriteriaTrigger(ipv4: IPAddress) -> AwakeTrigger {
        AwakeTrigger(name: "All", criteria: [
            .schedule(.init(weekdays: [.monday], startMinute: 0, endMinute: 1)),
            .systemIdleTime(.init(comparison: .greaterThan, value: 60)),
            .dnsServer([ipv4]),
            .wifiNetwork("Studio"),
            .ipAddress(.exact(ipv4)),
            .ciscoAnyConnectVPN("Work"),
            .volume(identifier: "volume-id"),
            .application(.init(identifier: "com.apple.TextEdit", requiresFrontmost: false)),
            .cpuUtilization(.init(comparison: .lessThan, value: 20)),
            .displays(.init(requirement: .mainDisplayMirrored, ignoresBuiltInDisplay: false)),
            .bluetoothDevice(identifier: "bluetooth-id"),
            .audioOutput(.device(identifier: "audio-id")),
            .usbDevice(identifier: "usb-id"),
            .batteryAndPowerAdapter(.init(
                minimumBatteryPercentage: 25,
                powerAdapter: .connected,
                combination: .and
            )),
        ])
    }
}

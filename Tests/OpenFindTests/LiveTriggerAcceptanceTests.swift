import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Live Trigger Acceptance Tests")
struct LiveTriggerAcceptanceTests {
    @Test func currentMacSignalsProduceMatchingAmphetamineCriteria() async throws {
        guard ProcessInfo.processInfo.environment["OPENFIND_LIVE_TRIGGER_ACCEPTANCE"] == "1" else {
            return
        }

        let provider = LocalTriggerSnapshotProvider()
        _ = provider.snapshot(requiredCriteria: [.cpuUtilization])
        let snapshot = provider.snapshot(
            requiredCriteria: Set(TriggerCriterion.Kind.allCases)
        )
        let criteria = matchingCriteria(for: snapshot)
        let kinds = Set(criteria.map(\.kind))

        for criterion in criteria {
            let trigger = try AwakeTrigger(
                name: "Live \(criterion.kind.rawValue)",
                criteria: [criterion]
            ).validated()
            #expect(
                TriggerEvaluator().evaluate(trigger, snapshot: snapshot).isMatch,
                "The live \(criterion.kind.rawValue) signal did not match its exact criterion."
            )
        }

        let aggregate = try AwakeTrigger(
            name: "Live aggregate",
            criteria: criteria
        ).validated()
        #expect(TriggerEvaluator().evaluate(aggregate, snapshot: snapshot).isMatch)

        let suiteName = "OpenFindTests.LiveTriggerAcceptance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        let triggerID = try store.add(aggregate)
        let assertions = LiveAcceptanceAssertions()
        let sessions = AwakeSessionController(assertions: assertions)
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)

        await coordinator.evaluate(snapshot: snapshot)
        #expect(coordinator.activeTriggerID == triggerID)
        #expect(sessions.activeSession?.source == .trigger(triggerID))
        #expect(assertions.activeConfiguration != nil)

        store.setEnabled(false)
        await coordinator.evaluate(snapshot: snapshot)
        #expect(!sessions.isActive)
        #expect(assertions.activeConfiguration == nil)

        let available = kinds.map(\.rawValue).sorted().joined(separator: ",")
        let unavailable = Set(TriggerCriterion.Kind.allCases)
            .subtracting(kinds)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        print("OPENFIND_LIVE_TRIGGER_ACCEPTED=\(available)")
        print("OPENFIND_LIVE_TRIGGER_UNAVAILABLE=\(unavailable)")
    }

    private func matchingCriteria(for snapshot: TriggerSnapshot) -> [TriggerCriterion] {
        var criteria: [TriggerCriterion] = []
        let calendar = Calendar.current
        if let weekday = TriggerWeekday(
            rawValue: calendar.component(.weekday, from: snapshot.date)
        ) {
            criteria.append(.schedule(.init(
                weekdays: [weekday],
                startMinute: 0,
                endMinute: 0
            )))
        }
        if let idle = snapshot.systemIdleTime {
            criteria.append(.systemIdleTime(.init(
                comparison: .lessThan,
                value: max(0.01, idle / 60 + 1)
            )))
        }
        if let dns = snapshot.dnsServers.first {
            criteria.append(.dnsServer([dns]))
        }
        if let ssid = snapshot.wifiSSID,
           isValid(.wifiNetwork(ssid)) {
            criteria.append(.wifiNetwork(ssid))
        }
        if let ip = snapshot.ipAddresses.first {
            criteria.append(.ipAddress(.exact(ip)))
        }
        if let vpn = snapshot.activeVPNServices.first(where: {
            isValid(.ciscoAnyConnectVPN($0))
        }) {
            criteria.append(.ciscoAnyConnectVPN(vpn))
        }
        if let volume = snapshot.mountedVolumeIdentifiers.first(where: {
            isValid(.volume(identifier: $0))
        }) {
            criteria.append(.volume(identifier: volume))
        }
        if let application = snapshot.runningApplicationIdentifiers.first(where: {
            isValid(.application(.init(identifier: $0, requiresFrontmost: false)))
        }) {
            criteria.append(.application(.init(
                identifier: application,
                requiresFrontmost: false
            )))
        }
        if let cpu = snapshot.cpuUtilizationPercentage {
            let threshold = cpu < 100
                ? ThresholdCriterion(comparison: .lessThan, value: min(100, cpu + 1))
                : ThresholdCriterion(comparison: .greaterThan, value: 99)
            criteria.append(.cpuUtilization(threshold))
        }
        if let count = snapshot.displayCount {
            criteria.append(.displays(.init(
                requirement: .count(comparison: .equal, value: count),
                ignoresBuiltInDisplay: false
            )))
        }
        if let bluetooth = snapshot.connectedBluetoothIdentifiers.first(where: {
            isValid(.bluetoothDevice(identifier: $0))
        }) {
            criteria.append(.bluetoothDevice(identifier: bluetooth))
        }
        if let audio = snapshot.audioOutputIdentifier,
           isValid(.audioOutput(.device(identifier: audio))) {
            criteria.append(.audioOutput(.device(identifier: audio)))
        }
        if let usb = snapshot.connectedUSBIdentifiers.first(where: {
            isValid(.usbDevice(identifier: $0))
        }) {
            criteria.append(.usbDevice(identifier: usb))
        }
        if snapshot.batteryPercentage != nil || snapshot.powerAdapterConnected != nil {
            criteria.append(.batteryAndPowerAdapter(.init(
                minimumBatteryPercentage: snapshot.batteryPercentage,
                powerAdapter: snapshot.powerAdapterConnected.map {
                    $0 ? .connected : .disconnected
                },
                combination: .and
            )))
        }
        return criteria
    }

    private func isValid(_ criterion: TriggerCriterion) -> Bool {
        (try? criterion.validated()) != nil
    }
}

private final class LiveAcceptanceAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

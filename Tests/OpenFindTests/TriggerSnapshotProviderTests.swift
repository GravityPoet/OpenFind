import AppKit
import AudioToolbox
import Foundation
import IOKit.ps
import Testing
@testable import OpenFind

@MainActor
@Suite("Trigger Snapshot Provider Tests")
struct TriggerSnapshotProviderTests {
    @Test func localProviderReturnsSafeBoundedSystemSignals() {
        let snapshot = LocalTriggerSnapshotProvider().snapshot(
            requiredCriteria: [.displays, .cpuUtilization, .systemIdleTime]
        )

        #expect(snapshot.displayCount == NSScreen.screens.count)
        #expect(snapshot.builtInDisplayCount >= 0)
        #expect(snapshot.builtInDisplayCount <= snapshot.displayCount ?? 0)
        if let cpu = snapshot.cpuUtilizationPercentage {
            #expect((0...100).contains(cpu))
        }
        if let idle = snapshot.systemIdleTime {
            #expect(idle >= 0)
        }
        if let battery = snapshot.batteryPercentage {
            #expect((0...100).contains(battery))
        }
    }

    @Test func sensitiveSignalsStayUnsetWhenTheirCriteriaAreNotRequested() {
        let snapshot = LocalTriggerSnapshotProvider().snapshot(requiredCriteria: [.displays])

        #expect(snapshot.wifiSSID == nil)
        #expect(snapshot.dnsServers.isEmpty)
        #expect(snapshot.ipAddresses.isEmpty)
        #expect(snapshot.connectedBluetoothIdentifiers.isEmpty)
        #expect(snapshot.connectedUSBIdentifiers.isEmpty)
        #expect(snapshot.batteryPercentage == nil)
    }

    @Test func wifiOnlySnapshotDoesNotCollectOtherNetworkIdentifiers() {
        let snapshot = LocalTriggerSnapshotProvider().snapshot(requiredCriteria: [.wifiNetwork])

        #expect(snapshot.dnsServers.isEmpty)
        #expect(snapshot.ipAddresses.isEmpty)
        #expect(snapshot.activeVPNServices.isEmpty)
    }

    @Test func cpuSamplerProducesAValueAfterTwoSamples() {
        let sampler = CPUUsageSampler()
        _ = sampler.sample()
        let value = sampler.sample()
        if let value {
            #expect((0...100).contains(value))
        }
    }

    @Test func batteryCapacityIsNormalizedAgainstReportedMaximum() {
        let snapshot = powerSourceSnapshot(from: [[
            kIOPSCurrentCapacityKey: NSNumber(value: 45),
            kIOPSMaxCapacityKey: NSNumber(value: 60),
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ] as NSDictionary])

        #expect(snapshot.batteryPercentage == 75)
        #expect(snapshot.adapterConnected == true)
    }

    @Test func processDiscoveryIncludesNonemptyNativeProcessNames() {
        let names = ProcessTriggerSignals.currentNames()

        #expect(!names.isEmpty)
        #expect(names.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 })
    }

    @Test func networkSignalsParseAllResolverScopesAndStayWellFormed() throws {
        let addresses = NetworkTriggerSignals.parsedDNSAddresses(from: [
            ["ServerAddresses": ["1.1.1.1", "invalid"]],
            ["ServerAddresses": ["2001:4860:4860::8888", "1.1.1.1"]],
        ])

        #expect(addresses == [
            try #require(IPAddress("1.1.1.1")),
            try #require(IPAddress("2001:4860:4860::8888")),
        ])

        let current = NetworkTriggerSignals.current(needsWiFi: false, needsNetwork: true)
        #expect(current.activeVPNServices.allSatisfy { !$0.isEmpty })
        #expect(current.ipAddresses.allSatisfy { !$0.description.isEmpty })
        #expect(current.dnsServers.allSatisfy { !$0.description.isEmpty })
    }

    @Test func dynamicVPNDetectionHandlesModernUtunAndLegacyInterfaceDictionaries() {
        #expect(NetworkTriggerSignals.isDynamicVPNState([
            "InterfaceName": "utun7",
        ]))
        #expect(NetworkTriggerSignals.isDynamicVPNState([
            "Interface": ["Type": "VPN", "DeviceName": "ppp0"],
        ]))
        #expect(!NetworkTriggerSignals.isDynamicVPNState([
            "InterfaceName": "en0",
            "ConfirmedInterfaceName": "en0",
        ]))
    }

    @Test func audioClassificationUsesCoreAudioTransportAndTerminalTypes() {
        #expect(HardwareTriggerSignals.classifyAudioOutput(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: [kAudioStreamTerminalTypeSpeaker]
        ) == .builtInSpeakers)
        #expect(HardwareTriggerSignals.classifyAudioOutput(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        ) == .wiredHeadphones)
        #expect(HardwareTriggerSignals.classifyAudioOutput(
            transportType: kAudioDeviceTransportTypeUSB,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        ) == .other)
        #expect(HardwareTriggerSignals.classifyAudioOutput(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: []
        ) == .builtInOutput)
    }
}

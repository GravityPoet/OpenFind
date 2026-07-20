import AppKit
import CoreGraphics
import Foundation

@MainActor
protocol TriggerSnapshotProviding: AnyObject {
    func snapshot(requiredCriteria: Set<TriggerCriterion.Kind>) -> TriggerSnapshot
}

@MainActor
final class LocalTriggerSnapshotProvider: TriggerSnapshotProviding {
    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let cpuSampler: CPUUsageSampler

    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default,
        cpuSampler: CPUUsageSampler = CPUUsageSampler()
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.cpuSampler = cpuSampler
    }

    func snapshot(requiredCriteria: Set<TriggerCriterion.Kind> = Set(TriggerCriterion.Kind.allCases)) -> TriggerSnapshot {
        let needsApplications = requiredCriteria.contains(.application)
        let applications = needsApplications ? runningApplicationIdentifiers() : []
        let frontmostApplication = needsApplications ? workspace.frontmostApplication : nil
        let frontmostApplications = applicationIdentifiers(for: frontmostApplication)
        let displayState = requiredCriteria.contains(.displays)
            ? displaySnapshot()
            : (count: 0, builtInCount: 0, isMirrored: false)
        // Wi-Fi SSID is a separate CoreWLAN signal. Do not collect the more
        // sensitive IP/DNS/VPN values unless one of those criteria is actually
        // configured for an enabled Trigger.
        let needsNetwork = !requiredCriteria.isDisjoint(with: [
            .dnsServer, .ipAddress, .ciscoAnyConnectVPN,
        ])
        let network = NetworkTriggerSignals.current(
            needsWiFi: requiredCriteria.contains(.wifiNetwork),
            needsNetwork: needsNetwork
        )
        let hardware = HardwareTriggerSignals.current(
            needsAudio: requiredCriteria.contains(.audioOutput),
            needsBluetooth: requiredCriteria.contains(.bluetoothDevice),
            needsUSB: requiredCriteria.contains(.usbDevice)
        )
        let power = requiredCriteria.contains(.batteryAndPowerAdapter)
            ? powerSnapshot()
            : (nil, nil)
        let volumes = requiredCriteria.contains(.volume) ? mountedVolumeIdentifiers() : []
        return TriggerSnapshot(
            date: Date(),
            systemIdleTime: requiredCriteria.contains(.systemIdleTime) ? systemIdleTime() : nil,
            dnsServers: network.dnsServers,
            wifiSSID: network.wifiSSID,
            ipAddresses: network.ipAddresses,
            activeVPNServices: network.activeVPNServices,
            mountedVolumeIdentifiers: volumes,
            runningApplicationIdentifiers: applications,
            frontmostApplicationIdentifier: frontmostApplication?.bundleIdentifier,
            frontmostApplicationIdentifiers: frontmostApplications,
            cpuUtilizationPercentage: requiredCriteria.contains(.cpuUtilization)
                ? cpuSampler.sample() : nil,
            displayCount: requiredCriteria.contains(.displays) ? displayState.count : nil,
            builtInDisplayCount: requiredCriteria.contains(.displays) ? displayState.builtInCount : 0,
            isMainDisplayMirrored: requiredCriteria.contains(.displays) ? displayState.isMirrored : nil,
            connectedBluetoothIdentifiers: hardware.connectedBluetoothIdentifiers,
            audioOutputIdentifier: hardware.audioOutputIdentifier,
            audioOutputKind: hardware.audioOutputKind,
            connectedUSBIdentifiers: hardware.connectedUSBIdentifiers,
            batteryPercentage: power.0,
            powerAdapterConnected: power.1
        )
    }

    private func systemIdleTime() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel,
        ]
        return eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? 0
    }

    private func mountedVolumeIdentifiers() -> Set<String> {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey]
        let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return Set(urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeUUIDString ?? url.standardizedFileURL.path
        })
    }

    private func displaySnapshot() -> (count: Int, builtInCount: Int, isMirrored: Bool) {
        var builtInCount = 0
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(displayID) != 0 { builtInCount += 1 }
        }
        // Amphetamine's “main display is mirrored” criterion is about the
        // main display, not whether any secondary display happens to belong
        // to a mirror set. Checking every screen can produce a false
        // positive on asymmetric mirror configurations.
        let mainDisplay = CGMainDisplayID()
        let mirrored = mainDisplay != kCGNullDirectDisplay
            && CGDisplayIsInMirrorSet(mainDisplay) != 0
        return (NSScreen.screens.count, builtInCount, mirrored)
    }

    private func powerSnapshot() -> (batteryPercentage: Double?, adapterConnected: Bool?) {
        let snapshot = currentPowerSourceSnapshot()
        return (snapshot.batteryPercentage, snapshot.adapterConnected)
    }

    private func runningApplicationIdentifiers() -> Set<String> {
        var identifiers = ProcessTriggerSignals.currentNames()
        for application in workspace.runningApplications {
            identifiers.formUnion(applicationIdentifiers(for: application))
        }
        return identifiers
    }

    private func applicationIdentifiers(for application: NSRunningApplication?) -> Set<String> {
        guard let application else { return [] }
        return Set([
            application.bundleIdentifier,
            application.localizedName,
            application.executableURL?.lastPathComponent,
            application.bundleURL?.deletingPathExtension().lastPathComponent,
        ].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        })
    }
}

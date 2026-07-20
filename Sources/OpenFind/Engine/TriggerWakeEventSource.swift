import AppKit
import Foundation
import SystemConfiguration

@MainActor
protocol TriggerWakeEventSourcing: AnyObject {
    func start(
        requiredCriteria: Set<TriggerCriterion.Kind>,
        handler: @escaping @MainActor () -> Void
    )
    func stop()
}

@MainActor
final class SystemTriggerWakeEventSource: TriggerWakeEventSourcing {
    private let workspaceCenter: NotificationCenter
    private let applicationCenter: NotificationCenter
    private let powerMonitor: any PowerSourceMonitoring
    private let networkMonitor: any TriggerSignalWakeMonitoring
    private let audioMonitor: any TriggerSignalWakeMonitoring
    private let bluetoothMonitor: any TriggerSignalWakeMonitoring
    private let usbMonitor: any TriggerSignalWakeMonitoring
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var handler: (@MainActor () -> Void)?
    private var hasReceivedInitialPowerSnapshot = false

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default,
        powerMonitor: any PowerSourceMonitoring = SystemPowerSourceMonitor(),
        networkMonitor: any TriggerSignalWakeMonitoring = NetworkConfigurationWakeMonitor(),
        audioMonitor: any TriggerSignalWakeMonitoring = AudioOutputWakeMonitor(),
        bluetoothMonitor: any TriggerSignalWakeMonitoring = BluetoothConnectionWakeMonitor(),
        usbMonitor: any TriggerSignalWakeMonitoring = USBDeviceWakeMonitor()
    ) {
        self.workspaceCenter = workspaceCenter
        self.applicationCenter = applicationCenter
        self.powerMonitor = powerMonitor
        self.networkMonitor = networkMonitor
        self.audioMonitor = audioMonitor
        self.bluetoothMonitor = bluetoothMonitor
        self.usbMonitor = usbMonitor
    }

    func start(
        requiredCriteria: Set<TriggerCriterion.Kind>,
        handler: @escaping @MainActor () -> Void
    ) {
        stop()
        self.handler = handler
        hasReceivedInitialPowerSnapshot = false
        var workspaceNames: [Notification.Name] = [NSWorkspace.didWakeNotification]
        if requiredCriteria.contains(.application) {
            workspaceNames += [
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.sessionDidBecomeActiveNotification,
            ]
        }
        if requiredCriteria.contains(.volume) {
            workspaceNames += [
                NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification,
            ]
        }
        for name in workspaceNames {
            let token = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handler?() }
            }
            observers.append((workspaceCenter, token))
        }
        if requiredCriteria.contains(.displays) {
            let displayToken = applicationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handler?() }
            }
            observers.append((applicationCenter, displayToken))
        }

        if requiredCriteria.contains(.schedule) {
            for name in [
                Notification.Name.NSSystemClockDidChange,
                Notification.Name.NSSystemTimeZoneDidChange,
                Notification.Name.NSCalendarDayChanged,
            ] {
                let token = applicationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handler?() }
                }
                observers.append((applicationCenter, token))
            }
        }

        if requiredCriteria.contains(.batteryAndPowerAdapter) {
            powerMonitor.start { [weak self] _ in
                guard let self else { return }
                guard self.hasReceivedInitialPowerSnapshot else {
                    self.hasReceivedInitialPowerSnapshot = true
                    return
                }
                self.handler?()
            }
        }
        let networkCriteria: Set<TriggerCriterion.Kind> = [
            .dnsServer, .wifiNetwork, .ipAddress, .ciscoAnyConnectVPN,
        ]
        if !requiredCriteria.isDisjoint(with: networkCriteria) {
            networkMonitor.start { [weak self] in self?.handler?() }
        }
        if requiredCriteria.contains(.audioOutput) {
            audioMonitor.start { [weak self] in self?.handler?() }
        }
        if requiredCriteria.contains(.bluetoothDevice) {
            bluetoothMonitor.start { [weak self] in self?.handler?() }
        }
        if requiredCriteria.contains(.usbDevice) {
            usbMonitor.start { [weak self] in self?.handler?() }
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        powerMonitor.stop()
        networkMonitor.stop()
        audioMonitor.stop()
        bluetoothMonitor.stop()
        usbMonitor.stop()
        hasReceivedInitialPowerSnapshot = false
        handler = nil
    }
}

@MainActor
final class NetworkConfigurationWakeMonitor: TriggerSignalWakeMonitoring {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var handler: (@MainActor () -> Void)?

    func start(handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault,
            "OpenFind.TriggerWake" as CFString,
            openFindNetworkConfigurationChanged,
            &context
        ) else { return }
        let patterns = ["State:/Network/.*"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns),
              let source = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, store, 0) else {
            return
        }
        self.store = store
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = nil
        }
        store = nil
        handler = nil
    }

    fileprivate func emit() {
        handler?()
    }
}

private let openFindNetworkConfigurationChanged: SCDynamicStoreCallBack = {
    _, _, info in
    guard let info else { return }
    let monitor = Unmanaged<NetworkConfigurationWakeMonitor>
        .fromOpaque(info)
        .takeUnretainedValue()
    MainActor.assumeIsolated { monitor.emit() }
}

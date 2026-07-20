import Foundation
import IOKit.ps

struct PowerSourceSnapshot: Equatable, Sendable {
    let batteryPercentage: Double?
    let adapterConnected: Bool?
}

func powerSourceSnapshot(from descriptions: [NSDictionary]) -> PowerSourceSnapshot {
    var batteryPercentage: Double?
    var sawPowerState = false
    var adapterConnected = false
    for description in descriptions {
        let type = description[kIOPSTypeKey] as? String
        if (type == kIOPSInternalBatteryType || type == nil),
           let current = description[kIOPSCurrentCapacityKey] as? NSNumber {
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            if maximum > 0 {
                batteryPercentage = min(100, max(0, current.doubleValue / maximum * 100))
            }
        }
        if let state = description[kIOPSPowerSourceStateKey] as? String {
            sawPowerState = true
            adapterConnected = adapterConnected || state == kIOPSACPowerValue
        }
    }
    return PowerSourceSnapshot(
        batteryPercentage: batteryPercentage,
        adapterConnected: sawPowerState ? adapterConnected : nil
    )
}

func currentPowerSourceSnapshot() -> PowerSourceSnapshot {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray
    let descriptions = sources.compactMap { source -> NSDictionary? in
        guard let unmanaged = IOPSGetPowerSourceDescription(info, source as CFTypeRef) else {
            return nil
        }
        return unmanaged.takeUnretainedValue() as NSDictionary
    }
    return powerSourceSnapshot(from: descriptions)
}

@MainActor
protocol PowerSourceMonitoring: AnyObject {
    func start(handler: @escaping @MainActor (PowerSourceSnapshot) -> Void)
    func stop()
    func snapshot() -> PowerSourceSnapshot
}

@MainActor
final class SystemPowerSourceMonitor: PowerSourceMonitoring {
    private var registration: PowerSourceRegistration?
    private var handler: (@MainActor (PowerSourceSnapshot) -> Void)?

    func start(handler: @escaping @MainActor (PowerSourceSnapshot) -> Void) {
        stop()
        self.handler = handler
        let callbackContext = Unmanaged.passRetained(PowerSourceCallbackContext(monitor: self))
        if let unmanagedSource = IOPSNotificationCreateRunLoopSource(
            openFindPowerSourceChanged,
            callbackContext.toOpaque()
        ) {
            let source = unmanagedSource.takeRetainedValue()
            registration = PowerSourceRegistration(
                source: source,
                callbackContext: callbackContext
            )
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        } else {
            callbackContext.release()
        }
        handler(snapshot())
    }

    func stop() {
        registration?.invalidate()
        registration = nil
        handler = nil
    }

    func snapshot() -> PowerSourceSnapshot {
        currentPowerSourceSnapshot()
    }

    fileprivate func emitCurrentSnapshot() {
        handler?(snapshot())
    }
}

private final class PowerSourceCallbackContext: @unchecked Sendable {
    @MainActor weak var monitor: SystemPowerSourceMonitor?

    @MainActor
    init(monitor: SystemPowerSourceMonitor) {
        self.monitor = monitor
    }
}

private final class PowerSourceRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var source: CFRunLoopSource?
    private var callbackContext: Unmanaged<PowerSourceCallbackContext>?

    init(
        source: CFRunLoopSource,
        callbackContext: Unmanaged<PowerSourceCallbackContext>
    ) {
        self.source = source
        self.callbackContext = callbackContext
    }

    func invalidate() {
        lock.lock()
        let source = self.source
        let callbackContext = self.callbackContext
        self.source = nil
        self.callbackContext = nil
        lock.unlock()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
        }
        callbackContext?.release()
    }

    deinit {
        invalidate()
    }
}

private let openFindPowerSourceChanged: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let callbackContext = Unmanaged<PowerSourceCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        callbackContext.monitor?.emitCurrentSnapshot()
    }
}

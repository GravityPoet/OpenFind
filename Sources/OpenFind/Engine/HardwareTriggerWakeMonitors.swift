import AudioToolbox
import Foundation
import IOBluetooth
import IOKit
import IOKit.usb

@MainActor
protocol TriggerSignalWakeMonitoring: AnyObject {
    func start(handler: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class AudioOutputWakeMonitor: TriggerSignalWakeMonitoring {
    private let queue = DispatchQueue.main
    private var handler: (@MainActor () -> Void)?
    private var systemRegistration: AudioListenerRegistration?
    private var deviceRegistrations: [AudioListenerRegistration] = []

    func start(handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler
        registerSystemListener()
        registerDeviceListeners()
    }

    func stop() {
        if let systemRegistration { remove(systemRegistration) }
        for registration in deviceRegistrations { remove(registration) }
        systemRegistration = nil
        deviceRegistrations.removeAll()
        handler = nil
    }

    private func registerSystemListener() {
        let propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.registerDeviceListeners()
                self.handler?()
            }
        }
        var mutableAddress = propertyAddress
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &mutableAddress,
            queue,
            listener
        ) == noErr else { return }
        systemRegistration = AudioListenerRegistration(
            object: AudioObjectID(kAudioObjectSystemObject),
            propertyAddress: propertyAddress,
            listener: listener
        )
    }

    private func registerDeviceListeners() {
        for registration in deviceRegistrations { remove(registration) }
        deviceRegistrations.removeAll()
        guard let device = HardwareTriggerSignals.defaultOutputDevice() else { return }

        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
        ]
        for propertyAddress in addresses {
            addDeviceListener(object: device, propertyAddress: propertyAddress)
        }
        for stream in HardwareTriggerSignals.outputStreams(for: device) {
            addDeviceListener(
                object: stream,
                propertyAddress: AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyTerminalType,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        }
    }

    private func addDeviceListener(
        object: AudioObjectID,
        propertyAddress: AudioObjectPropertyAddress
    ) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handler?() }
        }
        var mutableAddress = propertyAddress
        guard AudioObjectHasProperty(object, &mutableAddress),
              AudioObjectAddPropertyListenerBlock(
                  object,
                  &mutableAddress,
                  queue,
                  listener
              ) == noErr else { return }
        deviceRegistrations.append(.init(
            object: object,
            propertyAddress: propertyAddress,
            listener: listener
        ))
    }

    private func remove(_ registration: AudioListenerRegistration) {
        var propertyAddress = registration.propertyAddress
        AudioObjectRemovePropertyListenerBlock(
            registration.object,
            &propertyAddress,
            queue,
            registration.listener
        )
    }
}

private struct AudioListenerRegistration {
    let object: AudioObjectID
    let propertyAddress: AudioObjectPropertyAddress
    let listener: AudioObjectPropertyListenerBlock
}

@MainActor
final class BluetoothConnectionWakeMonitor: NSObject, TriggerSignalWakeMonitoring {
    private var handler: (@MainActor () -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    func start(handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        for case let device as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() as NSArray
            where device.isConnected() {
            registerDisconnect(for: device)
        }
    }

    func stop() {
        connectNotification?.unregister()
        for notification in disconnectNotifications.values { notification.unregister() }
        connectNotification = nil
        disconnectNotifications.removeAll()
        handler = nil
    }

    @objc nonisolated private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceReference = SendableBluetoothDeviceReference(device)
        Task { @MainActor [weak self, deviceReference] in
            guard let self, handler != nil else { return }
            registerDisconnect(for: deviceReference.device)
            handler?()
        }
    }

    @objc nonisolated private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceIdentifier = device.addressString
        Task { @MainActor [weak self] in
            guard let self, handler != nil else { return }
            if let deviceIdentifier {
                disconnectNotifications.removeValue(forKey: deviceIdentifier)
            }
            handler?()
        }
    }

    private func registerDisconnect(for device: IOBluetoothDevice) {
        guard let deviceIdentifier = device.addressString,
              disconnectNotifications[deviceIdentifier] == nil,
              let notification = device.register(
                  forDisconnectNotification: self,
                  selector: #selector(deviceDisconnected(_:device:))
              ) else { return }
        disconnectNotifications[deviceIdentifier] = notification
    }
}

private final class SendableBluetoothDeviceReference: @unchecked Sendable {
    let device: IOBluetoothDevice

    init(_ device: IOBluetoothDevice) {
        self.device = device
    }
}

@MainActor
final class USBDeviceWakeMonitor: TriggerSignalWakeMonitoring {
    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var callbackContext: Unmanaged<USBDeviceWakeCallbackContext>?
    private var handler: (@MainActor () -> Void)?

    func start(handler: @escaping @MainActor () -> Void) {
        stop()
        self.handler = handler
        guard let port = IONotificationPortCreate(kIOMainPortDefault),
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            stop()
            return
        }
        notificationPort = port
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let retainedContext = Unmanaged.passRetained(USBDeviceWakeCallbackContext(monitor: self))
        callbackContext = retainedContext
        let context = retainedContext.toOpaque()
        guard IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching(kIOUSBDeviceClassName),
            openFindUSBDeviceChanged,
            context,
            &matchedIterator
        ) == KERN_SUCCESS,
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching(kIOUSBDeviceClassName),
            openFindUSBDeviceChanged,
            context,
            &terminatedIterator
        ) == KERN_SUCCESS else {
            stop()
            return
        }
        drain(matchedIterator, notify: false)
        drain(terminatedIterator, notify: false)
    }

    func stop() {
        if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
        matchedIterator = 0
        terminatedIterator = 0
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
        callbackContext?.release()
        callbackContext = nil
        handler = nil
    }

    fileprivate func drain(_ iterator: io_iterator_t, notify: Bool) {
        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            found = true
            IOObjectRelease(service)
        }
        if notify, found { handler?() }
    }
}

private final class USBDeviceWakeCallbackContext: @unchecked Sendable {
    @MainActor weak var monitor: USBDeviceWakeMonitor?

    @MainActor
    init(monitor: USBDeviceWakeMonitor) {
        self.monitor = monitor
    }
}

private let openFindUSBDeviceChanged: IOServiceMatchingCallback = { context, iterator in
    guard let context else { return }
    let callbackContext = Unmanaged<USBDeviceWakeCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        callbackContext.monitor?.drain(iterator, notify: true)
    }
}

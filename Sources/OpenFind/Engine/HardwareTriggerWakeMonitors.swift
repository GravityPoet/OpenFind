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
        let address = AudioObjectPropertyAddress(
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
        var mutableAddress = address
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &mutableAddress,
            queue,
            listener
        ) == noErr else { return }
        systemRegistration = AudioListenerRegistration(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: address,
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
        for address in addresses {
            addDeviceListener(object: device, address: address)
        }
        for stream in HardwareTriggerSignals.outputStreams(for: device) {
            addDeviceListener(
                object: stream,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyTerminalType,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        }
    }

    private func addDeviceListener(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handler?() }
        }
        var mutableAddress = address
        guard AudioObjectHasProperty(object, &mutableAddress),
              AudioObjectAddPropertyListenerBlock(
                  object,
                  &mutableAddress,
                  queue,
                  listener
              ) == noErr else { return }
        deviceRegistrations.append(.init(
            object: object,
            address: address,
            listener: listener
        ))
    }

    private func remove(_ registration: AudioListenerRegistration) {
        var address = registration.address
        AudioObjectRemovePropertyListenerBlock(
            registration.object,
            &address,
            queue,
            registration.listener
        )
    }
}

private struct AudioListenerRegistration {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
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

    @objc private func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        registerDisconnect(for: device)
        handler?()
    }

    @objc private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        if let address = device.addressString {
            disconnectNotifications.removeValue(forKey: address)
        }
        handler?()
    }

    private func registerDisconnect(for device: IOBluetoothDevice) {
        guard let address = device.addressString,
              disconnectNotifications[address] == nil,
              let notification = device.register(
                  forDisconnectNotification: self,
                  selector: #selector(deviceDisconnected(_:device:))
              ) else { return }
        disconnectNotifications[address] = notification
    }
}

@MainActor
final class USBDeviceWakeMonitor: TriggerSignalWakeMonitoring {
    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
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

        let context = Unmanaged.passUnretained(self).toOpaque()
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
        }
        runLoopSource = nil
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
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

private let openFindUSBDeviceChanged: IOServiceMatchingCallback = { context, iterator in
    guard let context else { return }
    let monitor = Unmanaged<USBDeviceWakeMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.drain(iterator, notify: true) }
}

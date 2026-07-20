import AudioToolbox
import Foundation
import IOBluetooth
import IOKit
import IOKit.usb

struct HardwareTriggerSignals {
    let audioOutputIdentifier: String?
    let audioOutputKind: AudioOutputKind?
    let connectedBluetoothIdentifiers: Set<String>
    let connectedUSBIdentifiers: Set<String>

    static func current(needsAudio: Bool, needsBluetooth: Bool, needsUSB: Bool) -> Self {
        let audio = needsAudio ? audioOutput() : (nil, nil)
        return Self(
            audioOutputIdentifier: audio.0,
            audioOutputKind: audio.1,
            connectedBluetoothIdentifiers: needsBluetooth ? connectedBluetoothIdentifiers() : [],
            connectedUSBIdentifiers: needsUSB ? connectedUSBIdentifiers() : []
        )
    }

    private static func audioOutput() -> (identifier: String?, kind: AudioOutputKind?) {
        guard let device = defaultOutputDevice() else { return (nil, nil) }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFTypeRef>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let identifier = uid?.takeUnretainedValue() as? String else {
            return (nil, nil)
        }
        let transport = uint32Property(
            object: device,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let terminalTypes = Set(outputStreams(for: device).compactMap { stream in
            uint32Property(
                object: stream,
                selector: kAudioStreamPropertyTerminalType,
                scope: kAudioObjectPropertyScopeGlobal
            )
        })
        let kind = classifyAudioOutput(
            transportType: transport,
            terminalTypes: terminalTypes
        )
        return (identifier, kind)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func classifyAudioOutput(
        transportType: UInt32?,
        terminalTypes: Set<UInt32>
    ) -> AudioOutputKind {
        guard transportType == kAudioDeviceTransportTypeBuiltIn else { return .other }
        if terminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
            return .wiredHeadphones
        }
        if terminalTypes.contains(kAudioStreamTerminalTypeSpeaker) {
            return .builtInSpeakers
        }
        return .builtInOutput
    }

    private static func uint32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    static func outputStreams(for device: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var streams = [AudioStreamID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioStreamID>.stride
        )
        let status = streams.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        return status == noErr ? streams : []
    }

    private static func connectedBluetoothIdentifiers() -> Set<String> {
        let devices = IOBluetoothDevice.pairedDevices() as NSArray
        let identifiers: [String] = devices.flatMap { item in
            guard let device = item as? IOBluetoothDevice,
                  device.isConnected() else { return [String]() }
            return [device.addressString, device.nameOrAddress]
                .compactMap { value -> String? in
                    guard let value else { return nil }
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized.isEmpty ? nil : normalized
                }
        }
        return Set(identifiers)
    }

    private static func connectedUSBIdentifiers() -> Set<String> {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var identifiers: Set<String> = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let vendor = property(service, key: kUSBVendorID as NSString)
            let product = property(service, key: kUSBProductID as NSString)
            let serial = property(service, key: kUSBSerialNumberString as NSString)
            let name = property(service, key: kUSBProductString as NSString)
            let identifier = [vendor, product, serial ?? name]
                .compactMap { $0 }
                .joined(separator: ":")
            if !identifier.isEmpty { identifiers.insert(identifier) }
            if let name, !name.isEmpty { identifiers.insert(name) }
        }
        return identifiers
    }

    private static func property(_ service: io_registry_entry_t, key: NSString) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

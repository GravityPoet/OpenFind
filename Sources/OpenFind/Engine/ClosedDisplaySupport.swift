import Foundation
import IOKit
import IOKit.ps

protocol ClosedDisplaySupportDetecting: AnyObject {
    func supportsClosedDisplayMode() -> Bool
}

enum ClosedDisplayHardwareState: Equatable, Sendable {
    case open
    case closed
    case unknown
}

protocol ClosedDisplayHardwareInspecting: Sendable {
    func hasInternalBattery() -> Bool
    func clamshellState() -> ClosedDisplayHardwareState
}

struct SystemClosedDisplayHardwareInspector: ClosedDisplayHardwareInspecting {
    func hasInternalBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray
        for case let source as CFTypeRef in sources {
            guard let unmanaged = IOPSGetPowerSourceDescription(info, source) else { continue }
            let description = unmanaged.takeUnretainedValue() as NSDictionary
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
    }

    func clamshellState() -> ClosedDisplayHardwareState {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return .unknown }
        if let number = value as? NSNumber {
            return number.boolValue ? .closed : .open
        }
        return .unknown
    }
}

final class BatteryBasedClosedDisplaySupportDetector: ClosedDisplaySupportDetecting {
    private let hardware: any ClosedDisplayHardwareInspecting

    init(hardware: any ClosedDisplayHardwareInspecting = SystemClosedDisplayHardwareInspector()) {
        self.hardware = hardware
    }

    func supportsClosedDisplayMode() -> Bool {
        hardware.hasInternalBattery() && hardware.clamshellState() != .unknown
    }
}

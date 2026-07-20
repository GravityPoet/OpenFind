import Foundation
import IOKit.pwr_mgt

enum PowerAssertionKind: String, CaseIterable, Hashable, Sendable {
    case systemSleep
    case displaySleep
}

enum PowerAssertionCreationResult: Equatable, Sendable {
    case created(UInt32)
    case failed(Int32)
}

enum PowerAssertionReleaseResult: Equatable, Sendable {
    case released
    case alreadyReleased
    case failed(Int32)
}

protocol PowerAssertionClient: AnyObject {
    func create(kind: PowerAssertionKind, timeout: TimeInterval) -> PowerAssertionCreationResult
    func release(identifier: UInt32) -> PowerAssertionReleaseResult
}

final class IOKitPowerAssertionClient: PowerAssertionClient {
    func create(kind: PowerAssertionKind, timeout: TimeInterval) -> PowerAssertionCreationResult {
        var identifier: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithDescription(
            assertionType(for: kind) as NSString,
            "OpenFind Awake Session" as NSString,
            details(for: kind) as NSString,
            nil,
            nil,
            timeout,
            kIOPMAssertionTimeoutActionRelease as NSString,
            &identifier
        )
        guard status == kIOReturnSuccess else { return .failed(status) }
        return .created(identifier)
    }

    func release(identifier: UInt32) -> PowerAssertionReleaseResult {
        Self.releaseResult(for: IOPMAssertionRelease(identifier))
    }

    static func releaseResult(for status: Int32) -> PowerAssertionReleaseResult {
        switch status {
        case kIOReturnSuccess:
            return .released
        case kIOReturnNotFound, kIOReturnBadArgument:
            // Timed assertions are released by powerd when they expire. On
            // current macOS versions, releasing that formerly valid ID again
            // returns kIOReturnBadArgument instead of kIOReturnNotFound.
            return .alreadyReleased
        default:
            return .failed(status)
        }
    }

    private func assertionType(for kind: PowerAssertionKind) -> String {
        switch kind {
        case .systemSleep:
            return kIOPMAssertionTypePreventUserIdleSystemSleep
        case .displaySleep:
            return kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
    }

    private func details(for kind: PowerAssertionKind) -> String {
        switch kind {
        case .systemSleep:
            return "Prevent automatic idle system sleep during an active session."
        case .displaySleep:
            return "Prevent automatic idle display sleep during an active session."
        }
    }
}

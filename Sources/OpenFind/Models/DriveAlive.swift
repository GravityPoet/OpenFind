import Foundation

enum DriveAlivePolicy: String, Codable, CaseIterable, Sendable {
    case duringAwakeSession
    case whileOpenFindRuns
}

struct DriveAliveTarget: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var policy: DriveAlivePolicy

    init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        policy: DriveAlivePolicy = .duringAwakeSession
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.policy = policy
    }
}

enum DriveAliveTargetStatus: Equatable, Sendable {
    case inactive
    case writing
    case healthy(Date)
    case failed(DriveAliveFailure)
}

enum DriveAliveFailure: Equatable, Sendable, LocalizedError {
    case bookmarkInvalid
    case targetUnavailable
    case permissionDenied
    case readOnly
    case timedOut
    case writeAlreadyPending
    case markerConflict
    case unsupportedTarget
    case ioFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .bookmarkInvalid:
            return "The saved Drive Alive location can no longer be resolved."
        case .targetUnavailable:
            return "The Drive Alive target is currently unavailable."
        case .permissionDenied:
            return "OpenFind does not have permission to write to this target."
        case .readOnly:
            return "The Drive Alive target is read-only."
        case .timedOut:
            return "The Drive Alive write timed out."
        case .writeAlreadyPending:
            return "A previous Drive Alive write is still pending."
        case .markerConflict:
            return "The Drive Alive marker name is already used by another file."
        case .unsupportedTarget:
            return "Drive Alive requires a local or mounted file-system folder."
        case let .ioFailure(code):
            return "The Drive Alive write failed with system error \(code)."
        }
    }
}

enum DriveAliveStoreError: Error, Equatable, LocalizedError {
    case invalidTarget
    case duplicateTarget
    case invalidInterval
    case targetLimitReached
    case bookmarkTooLarge
    case dataTooLarge
    case targetNotFound

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "Select a valid local or mounted folder for Drive Alive."
        case .duplicateTarget:
            return "That Drive Alive target is already configured."
        case .invalidInterval:
            return "The Drive Alive interval must be between 1 second and 1 hour."
        case .targetLimitReached:
            return "The maximum number of Drive Alive targets has been reached."
        case .bookmarkTooLarge:
            return "The selected location produced an unexpectedly large bookmark."
        case .dataTooLarge:
            return "The saved Drive Alive configuration is too large."
        case .targetNotFound:
            return "The Drive Alive target no longer exists in the configuration."
        }
    }
}

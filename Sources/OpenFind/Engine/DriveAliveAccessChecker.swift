import Foundation

struct DriveAliveAccessResult: Sendable {
    let access: DriveAliveAccess
    var refreshedBookmarkData: Data?
}

protocol DriveAliveAccessChecking: Sendable {
    func inspect(_ target: DriveAliveTarget) async -> DriveAliveAccessResult
}

final class FileSystemDriveAliveAccessChecker: DriveAliveAccessChecking, Sendable {
    private let resolver: any DriveAliveBookmarkResolving
    private let executor = DriveAliveIOExecutor()

    init(resolver: any DriveAliveBookmarkResolving) { self.resolver = resolver }

    func inspect(_ target: DriveAliveTarget) async -> DriveAliveAccessResult {
        do {
            return try await executor.run(
                key: target.id.uuidString,
                timeout: .seconds(10),
                waitForPending: true
            ) { _ in
                let resource = try self.resolver.resolve(target.bookmarkData)
                defer { resource.close() }
                let values = try resource.url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
                guard values.isDirectory == true else { throw DriveAliveFailure.targetUnavailable }
                let access: DriveAliveAccess
                if values.volumeIsReadOnly == true {
                    access = .readOnly
                } else if !FileManager.default.isWritableFile(atPath: resource.url.path) {
                    access = .permissionDenied
                } else {
                    access = .writable
                }
                return DriveAliveAccessResult(access: access, refreshedBookmarkData: resource.refreshedBookmarkData)
            }
        } catch is CancellationError {
            return DriveAliveAccessResult(access: .unknown)
        } catch {
            switch DriveAliveFailure.from(error) {
            case .readOnly: return DriveAliveAccessResult(access: .readOnly)
            case .permissionDenied: return DriveAliveAccessResult(access: .permissionDenied)
            case .targetUnavailable, .bookmarkInvalid, .unsupportedTarget:
                return DriveAliveAccessResult(access: .unavailable)
            default: return DriveAliveAccessResult(access: .unknown)
            }
        }
    }
}

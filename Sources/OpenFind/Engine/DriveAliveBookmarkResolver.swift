import Foundation

protocol DriveAliveBookmarkResolving: Sendable {
    func bookmarkData(for directoryURL: URL) throws -> Data
    func resolve(_ bookmarkData: Data) throws -> DriveAliveResolvedResource
}

final class DriveAliveResolvedResource: @unchecked Sendable {
    let url: URL
    let refreshedBookmarkData: Data?

    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(
        url: URL,
        refreshedBookmarkData: Data? = nil,
        releaseAction: @escaping @Sendable () -> Void = {}
    ) {
        self.url = url
        self.refreshedBookmarkData = refreshedBookmarkData
        self.releaseAction = releaseAction
    }

    func close() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        close()
    }
}

struct SecurityScopedDriveAliveBookmarkResolver: DriveAliveBookmarkResolving {
    func bookmarkData(for directoryURL: URL) throws -> Data {
        guard directoryURL.isFileURL else { throw DriveAliveStoreError.invalidTarget }
        return try directoryURL.standardizedFileURL.bookmarkData(options: [.withSecurityScope])
    }

    func resolve(_ bookmarkData: Data) throws -> DriveAliveResolvedResource {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
        } catch {
            throw DriveAliveFailure.bookmarkInvalid
        }
        guard url.isFileURL else { throw DriveAliveFailure.unsupportedTarget }

        let accessed = url.startAccessingSecurityScopedResource()
        let refreshed = isStale ? try? self.bookmarkData(for: url) : nil
        return DriveAliveResolvedResource(
            url: url,
            refreshedBookmarkData: refreshed,
            releaseAction: {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
        )
    }
}

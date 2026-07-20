import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Drive Alive Controller Tests")
struct DriveAliveControllerTests {
    @Test func alwaysTargetsWriteWithoutAnAwakeSession() async throws {
        let suite = "OpenFindTests.DriveAliveController.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        store.setEnabled(true)
        let writer = FakeDriveAliveWriter()
        let sessions = AwakeSessionController(assertions: FakeControllerAssertions())
        let controller = DriveAliveController(
            store: store,
            sessions: sessions,
            resolver: resolver,
            writer: writer
        )

        await controller.refresh()

        #expect(writer.writtenURLs.count == 1)
        #expect(controller.statuses[id].map { if case .healthy = $0 { true } else { false } } == true)
    }

    @Test func sessionOnlyTargetsWaitForAnAwakeSession() async throws {
        let suite = "OpenFindTests.DriveAliveController.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let id = try store.add(directoryURL: FileManager.default.temporaryDirectory)
        store.setEnabled(true)
        let writer = FakeDriveAliveWriter()
        let sessions = AwakeSessionController(assertions: FakeControllerAssertions())
        let controller = DriveAliveController(
            store: store,
            sessions: sessions,
            resolver: resolver,
            writer: writer
        )

        await controller.refresh()
        #expect(writer.writtenURLs.isEmpty)
        #expect(controller.statuses[id] == .inactive)

        try sessions.start(.init())
        await controller.refresh()
        #expect(writer.writtenURLs.count == 1)
    }

    @Test func writerFailuresBecomeNonSensitiveStatuses() async throws {
        let suite = "OpenFindTests.DriveAliveController.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let id = try store.add(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .whileOpenFindRuns
        )
        store.setEnabled(true)
        let writer = FakeDriveAliveWriter()
        writer.error = .permissionDenied
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )

        await controller.refresh()

        #expect(controller.statuses[id] == .failed(.permissionDenied))
    }

    @Test func unavailableTargetCanStillBeRemovedFromConfiguration() async throws {
        let suite = "OpenFindTests.DriveAliveController.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FailingRemovalResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let id = try store.add(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .whileOpenFindRuns
        )
        resolver.shouldFailResolution = true
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: FakeDriveAliveWriter()
        )

        try await controller.removeTarget(id: id)

        #expect(store.targets.isEmpty)
        #expect(controller.statuses[id] == nil)
        #expect(controller.lastErrorMessage == DriveAliveFailure.targetUnavailable.localizedDescription)
    }
}

private struct FakeControllerResolver: DriveAliveBookmarkResolving {
    func bookmarkData(for directoryURL: URL) throws -> Data {
        Data(directoryURL.standardizedFileURL.path.utf8)
    }

    func resolve(_ bookmarkData: Data) throws -> DriveAliveResolvedResource {
        DriveAliveResolvedResource(
            url: URL(fileURLWithPath: String(decoding: bookmarkData, as: UTF8.self))
        )
    }
}

private final class FailingRemovalResolver: @unchecked Sendable, DriveAliveBookmarkResolving {
    var shouldFailResolution = false

    func bookmarkData(for directoryURL: URL) throws -> Data {
        Data(directoryURL.standardizedFileURL.path.utf8)
    }

    func resolve(_ bookmarkData: Data) throws -> DriveAliveResolvedResource {
        if shouldFailResolution { throw DriveAliveFailure.targetUnavailable }
        return DriveAliveResolvedResource(
            url: URL(fileURLWithPath: String(decoding: bookmarkData, as: UTF8.self))
        )
    }
}

private final class FakeDriveAliveWriter: @unchecked Sendable, DriveAliveWriting {
    private let lock = NSLock()
    private(set) var writtenURLs: [URL] = []
    var error: DriveAliveFailure?

    func write(to directoryURL: URL, timeout: Duration) async throws {
        let error = lock.withLock {
            writtenURLs.append(directoryURL)
            return self.error
        }
        if let error { throw error }
    }

    func removeMarker(from directoryURL: URL, timeout: Duration) async throws {}
}

private final class FakeControllerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?
    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }
    func deactivate() throws { activeConfiguration = nil }
}

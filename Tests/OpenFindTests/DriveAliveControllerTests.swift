import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Drive Alive Controller Tests")
struct DriveAliveControllerTests {
    @Test func disabledOrEmptyConfigurationDoesNotStartTheKeepAliveLoop() async throws {
        let suite = "OpenFindTests.DriveAliveControllerIdle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let writer = FakeDriveAliveWriter()
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )

        controller.start()
        #expect(!controller.isRunning)
        let id = try store.add(directoryURL: FileManager.default.temporaryDirectory)
        store.setEnabled(true)
        try await waitUntil { controller.isRunning }
        #expect(store.target(id: id) != nil)
        controller.stop()
        #expect(!controller.isRunning)
    }

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

    @Test func wakeWritesSingleTargetWithoutStartingLoop() async throws {
        let suite = "OpenFindTests.DriveAliveWake.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveWake.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        // Continuous mode stays disabled: wake must work on demand.
        #expect(!store.isEnabled)
        let writer = FakeDriveAliveWriter()
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )
        controller.start()
        #expect(!controller.isRunning)

        await controller.wake(targetID: id)

        #expect(writer.writtenURLs.count == 1)
        #expect(!controller.isRunning)
        #expect(controller.wakingTargetIDs.isEmpty)
        guard case let .healthy(date) = controller.statuses[id] else {
            Issue.record("Expected healthy status after wake")
            return
        }
        #expect(controller.lastSucceededAt[id] == date)
    }

    @Test func wakeFailureRecordsLastFailure() async throws {
        let suite = "OpenFindTests.DriveAliveWake.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let id = try store.add(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .whileOpenFindRuns
        )
        let writer = FakeDriveAliveWriter()
        writer.error = .readOnly
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )

        await controller.wake(targetID: id)

        #expect(controller.statuses[id] == .failed(.readOnly))
        #expect(controller.lastFailureByTarget[id] == .readOnly)
        #expect(controller.lastFailedAt[id] != nil)
        #expect(!controller.isRunning)
    }

    @Test func wakeWithRealWriterCreatesBoundedMarker() async throws {
        let suite = "OpenFindTests.DriveAliveWake.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveWakeReal.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        let writer = POSIXDriveAliveWriter(
            syncFile: { _ in 0 },
            operationScheduler: { operation in operation() }
        )
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )

        await controller.wake(targetID: id)

        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)
        let payload = try Data(contentsOf: marker)
        #expect(payload.count == POSIXDriveAliveWriter.payloadSize)
        #expect(payload.prefix(24) == Data("OpenFind Drive Alive v1\n".utf8))
        #expect(controller.lastSucceededAt[id] != nil)
        #expect(!controller.isRunning)
    }

    @Test func removeDuringWakeLeavesNoOrphanMarker() async throws {
        let suite = "OpenFindTests.DriveAliveWakeRemove.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveWakeRemove.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        let gated = GatedRealDriveAliveWriter()
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: gated
        )
        controller.start()

        let wakeTask = Task { @MainActor in
            await controller.wake(targetID: id)
        }
        try await waitUntil { gated.didEnterWrite }
        // Removal must wait for the in-flight wake, then clean its marker.
        let removeTask = Task { @MainActor in
            try await controller.removeTarget(id: id)
        }
        // Let removal reach its wait state before releasing the write.
        try await Task.sleep(for: .milliseconds(50))
        gated.release()
        await wakeTask.value
        try await removeTask.value

        #expect(store.targets.isEmpty)
        #expect(controller.statuses[id] == nil)
        #expect(controller.reachableTargetIDs.contains(id) == false)
        #expect(controller.wakingTargetIDs.contains(id) == false)
        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(gated.writeCount == 1)
        #expect(gated.removeCount == 1)
    }

    @Test func successThenUnavailableMarksDisconnected() async throws {
        let suite = "OpenFindTests.DriveAliveRevalidate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveGone.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        let writer = POSIXDriveAliveWriter(
            syncFile: { _ in 0 },
            operationScheduler: { operation in operation() }
        )
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )
        await controller.wake(targetID: id)
        guard case .healthy = controller.statuses[id] else {
            Issue.record("Expected healthy before the target disappears")
            return
        }
        #expect(controller.reachableTargetIDs.contains(id))
        #expect(controller.activeTargetCount == 1)

        try FileManager.default.removeItem(at: directory)
        await controller.revalidate(targetID: id)

        #expect(controller.reachableTargetIDs.contains(id) == false)
        #expect(controller.statuses[id] == .failed(.targetUnavailable))
        #expect(controller.activeTargetCount == 0)
        // History is preserved for the UI's “last success” line.
        #expect(controller.lastSucceededAt[id] != nil)
        #expect(controller.lastFailureByTarget[id] == .targetUnavailable)
    }

    @Test func refreshStatusNeverCreatesAMarker() async throws {
        let suite = "OpenFindTests.DriveAliveStatusOnly.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveStatusOnly.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        let writer = POSIXDriveAliveWriter(
            syncFile: { _ in 0 },
            operationScheduler: { operation in operation() }
        )
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )

        await controller.refreshStatus()

        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(controller.accessStates[id] == .writable)
        #expect(controller.statuses[id] == .inactive)
    }

    @Test func continuousAndManualWakeShareOneWriteSlot() async throws {
        let suite = "OpenFindTests.DriveAliveWriteSlot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let id = try store.add(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .whileOpenFindRuns
        )
        store.setEnabled(true)
        let writer = SerialCheckingDriveAliveWriter()
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: writer
        )

        let continuous = Task { @MainActor in await controller.refresh() }
        try await waitUntil { writer.didEnterWrite }
        let manual = Task { @MainActor in await controller.wake(targetID: id) }
        try await Task.sleep(for: .milliseconds(25))
        writer.release()
        await continuous.value
        await manual.value

        #expect(writer.writeCount == 1)
        #expect(writer.maximumConcurrentWrites == 1)
    }

    @Test func isRunningChangeDeliversObservation() async throws {
        let suite = "OpenFindTests.DriveAliveIsRunning.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeControllerResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let controller = DriveAliveController(
            store: store,
            sessions: AwakeSessionController(assertions: FakeControllerAssertions()),
            resolver: resolver,
            writer: FakeDriveAliveWriter()
        )
        controller.start()
        #expect(!controller.isRunning)

        let flag = ObservationFlag()
        withObservationTracking {
            _ = controller.isRunning
        } onChange: {
            flag.set()
        }
        _ = try store.add(
            directoryURL: FileManager.default.temporaryDirectory,
            policy: .whileOpenFindRuns
        )
        store.setEnabled(true)
        try await waitUntil { controller.isRunning }
        try await waitUntil { flag.value }

        #expect(controller.isRunning)
        #expect(flag.value)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
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

private final class GatedRealDriveAliveWriter: @unchecked Sendable, DriveAliveWriting {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var writes = 0
    private var removes = 0
    private let real = POSIXDriveAliveWriter(
        syncFile: { _ in 0 },
        operationScheduler: { operation in operation() }
    )

    var didEnterWrite: Bool { lock.withLock { entered } }
    var writeCount: Int { lock.withLock { writes } }
    var removeCount: Int { lock.withLock { removes } }

    func release() {
        lock.withLock { released = true }
    }

    func write(to directoryURL: URL, timeout: Duration) async throws {
        lock.withLock { entered = true }
        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        lock.withLock { writes += 1 }
        try await real.write(to: directoryURL, timeout: timeout)
    }

    func removeMarker(from directoryURL: URL, timeout: Duration) async throws {
        lock.withLock { removes += 1 }
        try await real.removeMarker(from: directoryURL, timeout: timeout)
    }
}

private final class SerialCheckingDriveAliveWriter: @unchecked Sendable, DriveAliveWriting {
    private let lock = NSLock()
    private var released = false
    private var activeWrites = 0
    private(set) var writeCount = 0
    private(set) var maximumConcurrentWrites = 0

    var didEnterWrite: Bool { lock.withLock { writeCount > 0 } }

    func release() {
        lock.withLock { released = true }
    }

    func write(to directoryURL: URL, timeout: Duration) async throws {
        lock.withLock {
            activeWrites += 1
            writeCount += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        }
        defer { lock.withLock { activeWrites -= 1 } }
        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func removeMarker(from directoryURL: URL, timeout: Duration) async throws {}
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class FakeControllerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?
    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }
    func deactivate() throws { activeConfiguration = nil }
}

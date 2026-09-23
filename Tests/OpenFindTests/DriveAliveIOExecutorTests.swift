import Foundation
import Testing
@testable import OpenFind

@Suite("Drive Alive I/O Executor Tests")
struct DriveAliveIOExecutorTests {
    @Test func timedOutQueuedWriteCannotRunAfterRemovalBegins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveExecutor.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scheduler = DeferredDriveAliveScheduler()
        let writer = POSIXDriveAliveWriter(
            syncFile: { _ in 0 },
            operationScheduler: { operation in scheduler.enqueue(operation) }
        )

        let timedOutWrite = Task {
            try? await writer.write(to: directory, timeout: .milliseconds(25))
        }
        try await waitUntil { scheduler.count == 1 }
        await timedOutWrite.value

        // removeMarker waits for the timed-out reservation, then queues its
        // cleanup operation behind the cancelled write. Running both queued
        // closures proves the stale write is discarded before cleanup runs.
        let removal = Task {
            try await writer.removeMarker(from: directory, timeout: .seconds(1))
        }
        try await waitUntil { scheduler.count == 2 }
        scheduler.runNext()
        scheduler.runNext()
        try await removal.value

        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(POSIXDriveAliveWriter.markerName).path
            ) == false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

private final class DeferredDriveAliveScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []

    var count: Int { lock.withLock { operations.count } }

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    func runNext() {
        let operation = lock.withLock { operations.isEmpty ? nil : operations.removeFirst() }
        operation?()
    }
}

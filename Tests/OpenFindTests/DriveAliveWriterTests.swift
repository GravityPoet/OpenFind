import Foundation
import Testing
@testable import OpenFind

@Suite("Drive Alive Writer Tests")
struct DriveAliveWriterTests {
    private func makeWriter() -> POSIXDriveAliveWriter {
        POSIXDriveAliveWriter(
            syncFile: { _ in 0 },
            operationScheduler: { operation in operation() }
        )
    }

    @Test func repeatedWritesKeepOneBoundedMarker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAlive.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = makeWriter()
        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)

        try await writer.write(to: directory, timeout: POSIXDriveAliveWriter.defaultTimeout)
        let first = try Data(contentsOf: marker)
        try await writer.write(to: directory, timeout: POSIXDriveAliveWriter.defaultTimeout)
        let second = try Data(contentsOf: marker)

        #expect(first.count == POSIXDriveAliveWriter.payloadSize)
        #expect(second.count == POSIXDriveAliveWriter.payloadSize)
        #expect(first.prefix(24) == Data("OpenFind Drive Alive v1\n".utf8))
        #expect(second.prefix(24) == Data("OpenFind Drive Alive v1\n".utf8))
        #expect(first != second)
    }

    @Test func existingUserFileIsNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAlive.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)
        let original = Data("user-owned-data".utf8)
        try original.write(to: marker)

        do {
            try await makeWriter().write(
                to: directory,
                timeout: POSIXDriveAliveWriter.defaultTimeout
            )
            Issue.record("A user-owned marker was unexpectedly overwritten")
        } catch let error as DriveAliveFailure {
            #expect(error == .markerConflict)
        }
        #expect(try Data(contentsOf: marker) == original)
    }

    @Test func markerSymlinkIsRejectedWithoutTouchingItsTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAlive.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let victim = directory.appendingPathComponent("victim")
        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)
        let original = Data("do-not-touch".utf8)
        try original.write(to: victim)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: victim)

        do {
            try await makeWriter().write(
                to: directory,
                timeout: POSIXDriveAliveWriter.defaultTimeout
            )
            Issue.record("A marker symlink was unexpectedly followed")
        } catch let error as DriveAliveFailure {
            #expect(error == .markerConflict)
        }
        #expect(try Data(contentsOf: victim) == original)
    }

    @Test func durableSyncFailureSurfacesAsIOFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAlive.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = POSIXDriveAliveWriter(
            syncFile: { _ in -1 },
            operationScheduler: { operation in operation() }
        )

        do {
            try await writer.write(
                to: directory,
                timeout: POSIXDriveAliveWriter.defaultTimeout
            )
            Issue.record("A failed durable sync was unexpectedly reported as successful")
        } catch let error as DriveAliveFailure {
            guard case .ioFailure = error else {
                Issue.record("Expected an I/O failure, received \(error)")
                return
            }
        }
    }
}

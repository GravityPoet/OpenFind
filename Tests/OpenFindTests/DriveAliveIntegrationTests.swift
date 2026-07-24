import Foundation
import Testing
@testable import OpenFind

@Suite(
    "Drive Alive Integration Tests",
    .serialized,
    .enabled(if:
        ProcessInfo.processInfo.environment["OPENFIND_RUN_DRIVE_ALIVE_INTEGRATION"] == "1"
    )
)
struct DriveAliveIntegrationTests {
    @Test func productionQueueAndDurableSyncWriteTheMarker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveIntegration.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await POSIXDriveAliveWriter().write(
            to: directory,
            timeout: POSIXDriveAliveWriter.defaultTimeout
        )

        let marker = directory.appendingPathComponent(POSIXDriveAliveWriter.markerName)
        let payload = try Data(contentsOf: marker)
        #expect(payload.count == POSIXDriveAliveWriter.payloadSize)
        #expect(payload.prefix(24) == Data("OpenFind Drive Alive v1\n".utf8))
    }
}

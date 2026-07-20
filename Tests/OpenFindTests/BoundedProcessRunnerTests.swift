import Foundation
import Testing
@testable import OpenFind

@Suite("Bounded Process Runner Tests")
struct BoundedProcessRunnerTests {
    @Test func capturesBoundedOutputFromASuccessfulProcess() async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["openfind"],
            timeout: 1,
            outputLimit: 1_024
        )

        #expect(result.terminationStatus == 0)
        #expect(!result.timedOut)
        #expect(!result.outputExceededLimit)
        #expect(String(decoding: result.output, as: UTF8.self) == "openfind\n")
    }

    @Test func killsAProcessThatExceedsItsOutputLimit() async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            timeout: 2,
            outputLimit: 4_096
        )

        #expect(result.outputExceededLimit)
        #expect(!result.timedOut)
        #expect(result.output.count == 4_096)
    }

    @Test func killsAProcessAtTheTimeoutBoundary() async throws {
        let started = ContinuousClock.now
        let result = try await BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.05,
            outputLimit: 1_024
        )

        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}

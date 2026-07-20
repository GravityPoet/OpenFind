import Foundation
import Testing
@testable import OpenFind

@Suite("Power Assertion Engine Tests")
struct PowerAssertionEngineTests {
    @Test func preventsSystemAndDisplaySleepByDefault() throws {
        let client = FakePowerAssertionClient()
        let engine = PowerAssertionEngine(client: client)

        try engine.activate(.init(allowsDisplaySleep: false, timeout: 600))

        #expect(client.creations.map(\.kind) == [.systemSleep, .displaySleep])
        #expect(client.creations.map(\.timeout) == [600, 600])
        #expect(engine.hasUnreleasedAssertions)
    }

    @Test func allowingDisplaySleepOnlyKeepsTheSystemAwake() throws {
        let client = FakePowerAssertionClient()
        let engine = PowerAssertionEngine(client: client)

        try engine.activate(.init(allowsDisplaySleep: true, timeout: 0))

        #expect(client.creations.map(\.kind) == [.systemSleep])
        #expect(client.creations.first?.timeout == 0)
    }

    @Test func failedReplacementPreservesTheExistingAssertions() throws {
        let client = FakePowerAssertionClient()
        let engine = PowerAssertionEngine(client: client)
        try engine.activate(.init(allowsDisplaySleep: true, timeout: 0))
        let originalIdentifier = try #require(client.creations.first?.identifier)
        client.creationFailure = (.displaySleep, -77)

        #expect(throws: PowerAssertionError.creationFailed(kind: .displaySleep, status: -77)) {
            try engine.activate(.init(allowsDisplaySleep: false, timeout: 120))
        }

        #expect(!client.releasedIdentifiers.contains(originalIdentifier))
        #expect(engine.activeConfiguration == .init(allowsDisplaySleep: true, timeout: 0))
        #expect(client.releasedIdentifiers.count == 1)
    }

    @Test func successfulReplacementReleasesSupersededAssertions() throws {
        let client = FakePowerAssertionClient()
        let engine = PowerAssertionEngine(client: client)
        try engine.activate(.init(allowsDisplaySleep: false, timeout: 30))
        let oldIdentifiers = Set(client.creations.map(\.identifier))

        try engine.activate(.init(allowsDisplaySleep: true, timeout: 60))

        #expect(Set(client.releasedIdentifiers) == oldIdentifiers)
        #expect(engine.activeConfiguration == .init(allowsDisplaySleep: true, timeout: 60))
    }

    @Test func releaseFailuresRemainRetryable() throws {
        let client = FakePowerAssertionClient()
        let engine = PowerAssertionEngine(client: client)
        try engine.activate(.init(allowsDisplaySleep: true, timeout: 0))
        let identifier = try #require(client.creations.first?.identifier)
        client.releaseFailures[identifier] = -88

        #expect(throws: PowerAssertionError.self) { try engine.deactivate() }
        #expect(engine.hasUnreleasedAssertions)

        client.releaseFailures.removeValue(forKey: identifier)
        try engine.deactivate()
        #expect(!engine.hasUnreleasedAssertions)
    }

    @Test func rejectsInvalidTimeoutBeforeCallingIOKit() {
        let client = FakePowerAssertionClient()
        let engine = PowerAssertionEngine(client: client)

        #expect(throws: PowerAssertionError.invalidTimeout) {
            try engine.activate(.init(allowsDisplaySleep: true, timeout: .nan))
        }
        #expect(client.creations.isEmpty)
    }
}

private final class FakePowerAssertionClient: PowerAssertionClient {
    struct Creation: Equatable {
        let kind: PowerAssertionKind
        let timeout: TimeInterval
        let identifier: UInt32
    }

    var creationFailure: (PowerAssertionKind, Int32)?
    var releaseFailures: [UInt32: Int32] = [:]
    private(set) var creations: [Creation] = []
    private(set) var releasedIdentifiers: [UInt32] = []
    private var nextIdentifier: UInt32 = 1

    func create(kind: PowerAssertionKind, timeout: TimeInterval) -> PowerAssertionCreationResult {
        if let failure = creationFailure, failure.0 == kind { return .failed(failure.1) }
        let identifier = nextIdentifier
        nextIdentifier += 1
        creations.append(.init(kind: kind, timeout: timeout, identifier: identifier))
        return .created(identifier)
    }

    func release(identifier: UInt32) -> PowerAssertionReleaseResult {
        releasedIdentifiers.append(identifier)
        if let status = releaseFailures[identifier] { return .failed(status) }
        return .released
    }
}

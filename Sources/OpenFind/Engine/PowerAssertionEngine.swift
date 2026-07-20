import Foundation

struct PowerAssertionConfiguration: Equatable, Sendable {
    var allowsDisplaySleep: Bool
    var timeout: TimeInterval
}

struct PowerAssertionReleaseFailure: Equatable, Sendable {
    let kind: PowerAssertionKind
    let identifier: UInt32
    let status: Int32
}

enum PowerAssertionError: Error, Equatable, LocalizedError {
    case invalidTimeout
    case creationFailed(kind: PowerAssertionKind, status: Int32)
    case releaseFailed([PowerAssertionReleaseFailure])

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "The power assertion timeout must be finite and nonnegative."
        case let .creationFailed(kind, status):
            return "Creating the \(kind.rawValue) assertion failed with IOKit status \(status)."
        case let .releaseFailed(failures):
            return "Releasing \(failures.count) power assertion(s) failed."
        }
    }
}

protocol PowerAssertionControlling: AnyObject {
    var activeConfiguration: PowerAssertionConfiguration? { get }
    func activate(_ configuration: PowerAssertionConfiguration) throws
    func deactivate() throws
}

final class PowerAssertionEngine: PowerAssertionControlling {
    private struct ManagedAssertion: Equatable {
        let kind: PowerAssertionKind
        let identifier: UInt32
    }

    private let client: any PowerAssertionClient
    private var activeAssertions: [PowerAssertionKind: UInt32] = [:]
    private var staleAssertions: [ManagedAssertion] = []
    private(set) var activeConfiguration: PowerAssertionConfiguration?
    private(set) var lastCleanupFailures: [PowerAssertionReleaseFailure] = []

    init(client: any PowerAssertionClient = IOKitPowerAssertionClient()) {
        self.client = client
    }

    var hasUnreleasedAssertions: Bool {
        !activeAssertions.isEmpty || !staleAssertions.isEmpty
    }

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        guard configuration.timeout.isFinite, configuration.timeout >= 0 else {
            throw PowerAssertionError.invalidTimeout
        }
        guard configuration != activeConfiguration else {
            retryStaleAssertions()
            return
        }

        var replacements: [PowerAssertionKind: UInt32] = [:]
        for kind in requiredKinds(for: configuration) {
            switch client.create(kind: kind, timeout: configuration.timeout) {
            case let .created(identifier):
                replacements[kind] = identifier
            case let .failed(status):
                preserveReleaseFailures(from: managedAssertions(in: replacements))
                throw PowerAssertionError.creationFailed(kind: kind, status: status)
            }
        }

        let superseded = managedAssertions(in: activeAssertions) + staleAssertions
        activeAssertions = replacements
        activeConfiguration = configuration
        staleAssertions = []
        preserveReleaseFailures(from: superseded)
    }

    func deactivate() throws {
        let desired = managedAssertions(in: activeAssertions)
        let desiredIDs = Set(desired.map(\.identifier))
        let failures = release(desired + staleAssertions)
        let failedIDs = Set(failures.map(\.identifier))

        activeAssertions = activeAssertions.filter { failedIDs.contains($0.value) }
        staleAssertions = failures.compactMap { failure in
            guard !desiredIDs.contains(failure.identifier) else { return nil }
            return ManagedAssertion(kind: failure.kind, identifier: failure.identifier)
        }
        lastCleanupFailures = failures
        if activeAssertions.isEmpty { activeConfiguration = nil }
        guard failures.isEmpty else { throw PowerAssertionError.releaseFailed(failures) }
    }

    deinit {
        for assertion in managedAssertions(in: activeAssertions) + staleAssertions {
            _ = client.release(identifier: assertion.identifier)
        }
    }

    private func requiredKinds(
        for configuration: PowerAssertionConfiguration
    ) -> [PowerAssertionKind] {
        configuration.allowsDisplaySleep ? [.systemSleep] : [.systemSleep, .displaySleep]
    }

    private func managedAssertions(
        in assertions: [PowerAssertionKind: UInt32]
    ) -> [ManagedAssertion] {
        PowerAssertionKind.allCases.compactMap { kind in
            assertions[kind].map { ManagedAssertion(kind: kind, identifier: $0) }
        }
    }

    private func preserveReleaseFailures(from assertions: [ManagedAssertion]) {
        let failures = release(assertions)
        lastCleanupFailures = failures
        staleAssertions.append(contentsOf: failures.map {
            ManagedAssertion(kind: $0.kind, identifier: $0.identifier)
        })
    }

    private func retryStaleAssertions() {
        let failures = release(staleAssertions)
        lastCleanupFailures = failures
        staleAssertions = failures.map {
            ManagedAssertion(kind: $0.kind, identifier: $0.identifier)
        }
    }

    private func release(_ assertions: [ManagedAssertion]) -> [PowerAssertionReleaseFailure] {
        assertions.compactMap { assertion in
            guard case let .failed(status) = client.release(identifier: assertion.identifier) else {
                return nil
            }
            return PowerAssertionReleaseFailure(
                kind: assertion.kind,
                identifier: assertion.identifier,
                status: status
            )
        }
    }
}

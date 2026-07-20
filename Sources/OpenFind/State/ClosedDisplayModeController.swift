import Foundation
import Observation

@MainActor
protocol ClosedDisplayModeManaging: AnyObject {
    var isEnabled: Bool { get }
    var isSupported: Bool { get }
    var hasPendingRestoration: Bool { get }
    func recoverIfNeeded() async -> Bool
    func reconcileAfterPowerSourceChange() async -> Bool
    func enable() async throws
    func disable() async throws
}

extension ClosedDisplayModeManaging {
    var isSupported: Bool { true }
    func reconcileAfterPowerSourceChange() async -> Bool { true }
}

@MainActor
@Observable
final class ClosedDisplayModeController: ClosedDisplayModeManaging {
    enum State: Equatable {
        case unsupported
        case disabled
        case enabled
        case error(String)
    }

    private struct Journal: Codable, Equatable {
        let originalValue: Bool
        let managedValue: Bool
    }

    private static let journalKey = "OpenFind.closedDisplayJournalV1"
    private let power: any ClosedDisplayPowerClient
    private let support: any ClosedDisplaySupportDetecting
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var state: State = .disabled

    init(
        power: any ClosedDisplayPowerClient = PMSetClosedDisplayPowerClient(),
        support: any ClosedDisplaySupportDetecting = BatteryBasedClosedDisplaySupportDetector(),
        defaults: UserDefaults = .standard
    ) {
        self.power = power
        self.support = support
        self.defaults = defaults
        if !support.supportsClosedDisplayMode() { state = .unsupported }
    }

    var isEnabled: Bool {
        if case .enabled = state { return true }
        return false
    }

    var isSupported: Bool {
        support.supportsClosedDisplayMode()
    }

    var hasPendingRestoration: Bool {
        defaults.data(forKey: Self.journalKey) != nil
    }

    func recoverIfNeeded() async -> Bool {
        do {
            guard let journal = try loadJournal() else { return true }
            let current = try await power.readSleepDisabled()
            if current == journal.managedValue,
               current != journal.originalValue {
                try await power.setSleepDisabled(journal.originalValue)
            }
            removeJournal()
            state = restingState
            return true
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    func reconcileAfterPowerSourceChange() async -> Bool {
        do {
            guard let journal = try loadJournal(),
                  journal.managedValue,
                  isEnabled else { return true }
            if try await power.readSleepDisabled() == journal.managedValue {
                return true
            }
            guard try await power.setSleepDisabledWithoutPrompt(journal.managedValue) else {
                state = .error(ClosedDisplayModeError.powerChangeUnprotected.localizedDescription)
                return false
            }
            state = .enabled
            return true
        } catch is CancellationError {
            return false
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    func enable() async throws {
        guard !isEnabled else { return }
        guard support.supportsClosedDisplayMode() else {
            state = .unsupported
            throw ClosedDisplayModeError.unsupported
        }
        guard await recoverIfNeeded() else { throw ClosedDisplayModeError.recoveryFailed }
        let original = try await power.readSleepDisabled()
        try saveJournal(.init(originalValue: original, managedValue: true))
        do {
            if !original { try await power.setSleepDisabled(true) }
            state = .enabled
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func disable() async throws {
        guard state != .unsupported || hasPendingRestoration else { return }
        do {
            guard let journal = try loadJournal() else {
                state = restingState
                return
            }
            let current = try await power.readSleepDisabled()
            if current == journal.managedValue,
               current != journal.originalValue {
                try await power.setSleepDisabled(journal.originalValue)
            }
            removeJournal()
            state = restingState
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    private func loadJournal() throws -> Journal? {
        guard let data = defaults.data(forKey: Self.journalKey) else { return nil }
        do {
            return try JSONDecoder().decode(Journal.self, from: data)
        } catch {
            throw ClosedDisplayModeError.journalCorrupt
        }
    }

    private func saveJournal(_ journal: Journal) throws {
        defaults.set(try JSONEncoder().encode(journal), forKey: Self.journalKey)
    }

    private func removeJournal() {
        defaults.removeObject(forKey: Self.journalKey)
    }

    private var restingState: State {
        support.supportsClosedDisplayMode() ? .disabled : .unsupported
    }
}

enum ClosedDisplayModeError: Error, Equatable, LocalizedError {
    case unsupported
    case recoveryFailed
    case journalCorrupt
    case powerChangeUnprotected

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Closed-display mode is only available on supported portable Macs."
        case .recoveryFailed:
            return "OpenFind could not reconcile the previous closed-display state."
        case .journalCorrupt:
            return "The closed-display recovery record is invalid and was left untouched."
        case .powerChangeUnprotected:
            return "Closed-display protection was reset after a power-source change. The session was ended safely; install Power Protect to reapply it automatically."
        }
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class TriggerStore {
    private static let enabledKey = "OpenFind.awakeTriggersEnabledV1"
    private static let dataKey = "OpenFind.awakeTriggersV1"
    private static let maximumDataSize = 2 * 1_024 * 1_024

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    private(set) var triggers: [AwakeTrigger]
    private(set) var loadErrorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let loaded = Self.loadTriggers(from: defaults)
        triggers = loaded.triggers
        loadErrorMessage = loaded.errorMessage
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    @discardableResult
    func add(_ trigger: AwakeTrigger) throws -> UUID {
        let normalized = try validatedUnique(trigger)
        let updated = triggers + [normalized]
        try persist(updated)
        triggers = updated
        return normalized.id
    }

    func update(_ trigger: AwakeTrigger) throws {
        guard let index = triggers.firstIndex(where: { $0.id == trigger.id }) else {
            throw TriggerStoreError.notFound
        }
        let normalized = try validatedUnique(trigger, excluding: trigger.id)
        var updated = triggers
        updated[index] = normalized
        try persist(updated)
        triggers = updated
    }

    func remove(id: UUID) throws {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else {
            throw TriggerStoreError.notFound
        }
        var updated = triggers
        updated.remove(at: index)
        try persist(updated)
        triggers = updated
    }

    func setTriggerEnabled(_ enabled: Bool, id: UUID) throws {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else {
            throw TriggerStoreError.notFound
        }
        var updated = triggers
        updated[index].isEnabled = enabled
        try persist(updated)
        triggers = updated
    }

    func move(from source: Int, to destination: Int) throws {
        guard triggers.indices.contains(source), (0...triggers.count).contains(destination) else {
            throw TriggerStoreError.invalidMove
        }
        var updated = triggers
        let item = updated.remove(at: source)
        let adjustedDestination = destination > source ? destination - 1 : destination
        updated.insert(item, at: min(adjustedDestination, updated.count))
        try persist(updated)
        triggers = updated
    }

    func clearLoadError() {
        loadErrorMessage = nil
    }

    private func validatedUnique(
        _ trigger: AwakeTrigger,
        excluding excludedID: UUID? = nil
    ) throws -> AwakeTrigger {
        let normalized = try trigger.validated()
        let duplicate = triggers.contains { existing in
            existing.id != excludedID
                && existing.name.caseInsensitiveCompare(normalized.name) == .orderedSame
        }
        guard !duplicate else { throw AwakeTriggerValidationError.duplicateName }
        return normalized
    }

    private func persist(_ triggers: [AwakeTrigger]) throws {
        let data = try JSONEncoder().encode(triggers)
        guard data.count <= Self.maximumDataSize else { throw TriggerStoreError.dataTooLarge }
        defaults.set(data, forKey: Self.dataKey)
    }

    private static func loadTriggers(
        from defaults: UserDefaults
    ) -> (triggers: [AwakeTrigger], errorMessage: String?) {
        guard let data = defaults.data(forKey: dataKey) else { return ([], nil) }
        guard data.count <= maximumDataSize,
              let decoded = try? JSONDecoder().decode([AwakeTrigger].self, from: data) else {
            return ([], "Saved Trigger data could not be read and was left untouched.")
        }
        var valid: [AwakeTrigger] = []
        var names: Set<String> = []
        for trigger in decoded {
            guard let normalized = try? trigger.validated() else { continue }
            let key = normalized.name.localizedLowercase
            guard names.insert(key).inserted else { continue }
            valid.append(normalized)
        }
        let dropped = decoded.count - valid.count
        return dropped == 0
            ? (valid, nil)
            : (valid, "Some saved Triggers were invalid and were skipped.")
    }
}

enum TriggerStoreError: Error, Equatable, LocalizedError {
    case notFound
    case invalidMove
    case dataTooLarge

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "The Trigger no longer exists."
        case .invalidMove:
            return "The Trigger order change is invalid."
        case .dataTooLarge:
            return "The saved Trigger data is too large."
        }
    }
}

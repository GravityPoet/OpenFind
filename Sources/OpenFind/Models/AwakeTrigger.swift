import Foundation

struct AwakeTrigger: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var criteria: [TriggerCriterion]
    var sessionOptions: AwakeSessionOptions

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        criteria: [TriggerCriterion],
        sessionOptions: AwakeSessionOptions = .defaultValue
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.criteria = criteria
        self.sessionOptions = sessionOptions
    }

    func validated() throws -> Self {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.count <= 100,
              normalizedName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AwakeTriggerValidationError.invalidName
        }
        guard !criteria.isEmpty else { throw AwakeTriggerValidationError.noCriteria }
        let kinds = criteria.map(\.kind)
        guard Set(kinds).count == kinds.count else {
            throw AwakeTriggerValidationError.duplicateCriterion
        }
        _ = try criteria.map { try $0.validated() }
        let normalizedOptions = try sessionOptions.validated()

        var normalized = self
        normalized.name = normalizedName
        normalized.sessionOptions = normalizedOptions
        return normalized
    }
}

enum AwakeTriggerValidationError: Error, Equatable, LocalizedError {
    case invalidName
    case noCriteria
    case duplicateCriterion
    case duplicateName
    case invalidCriterion(TriggerCriterion.Kind)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "The Trigger name is invalid."
        case .noCriteria:
            return "A Trigger requires at least one criterion."
        case .duplicateCriterion:
            return "A Trigger can use each criterion type only once."
        case .duplicateName:
            return "Trigger names must be unique."
        case let .invalidCriterion(kind):
            return "The \(kind.rawValue) Trigger criterion is invalid."
        }
    }
}

import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case search
    case keepAwake
    case triggers
    case driveAlive
    case clipboard
    case keyboardCleaning

    static let persistenceKey = "OpenFind.settings.selectedPaneV1"
    static let navigationOrder: [Self] = [
        .search, .clipboard, .keepAwake, .triggers, .driveAlive, .keyboardCleaning,
    ]

    var id: Self { self }

    var label: String {
        switch self {
        case .search: L("Search")
        case .clipboard: L("Clipboard History")
        case .keepAwake: L("Keep Awake")
        case .triggers: L("Triggers")
        case .driveAlive: L("Drive Alive")
        case .keyboardCleaning: L("Keyboard Cleaning")
        }
    }

    static func resolve(_ persistedValue: String) -> Self {
        Self(rawValue: persistedValue) ?? .search
    }
}

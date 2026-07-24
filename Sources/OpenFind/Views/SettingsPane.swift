import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case search
    case keepAwake
    case triggers
    case driveAlive
    case clipboard
    case keyboardCleaning

    static let persistenceKey = "OpenFind.settings.selectedPaneV1"

    var id: Self { self }

    static func resolve(_ persistedValue: String) -> Self {
        Self(rawValue: persistedValue) ?? .search
    }
}

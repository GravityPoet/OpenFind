import Foundation

enum AppLocalization {
    static let supportedIdentifiers = ["en", "zh-Hans"]
    static let fallbackIdentifier = "en"

    static func preferredIdentifier(for preferredLanguages: [String]) -> String {
        Bundle.preferredLocalizations(
            from: supportedIdentifiers,
            forPreferences: preferredLanguages
        ).first ?? fallbackIdentifier
    }

    static let identifier = preferredIdentifier(for: Locale.preferredLanguages)

    static let bundle: Bundle = {
        localizedBundle(for: identifier) ?? localizedBundle(for: fallbackIdentifier) ?? .main
    }()

    private static func localizedBundle(for identifier: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}

/// Retrieves localized strings from the standard application Resources folder.
/// Base language is English (keys themselves are English).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppLocalization.bundle)
}

/// Dynamic-key variant for values that come from state instead of literals.
func LD(_ key: String) -> String {
    AppLocalization.bundle.localizedString(forKey: key, value: nil, table: "Localizable")
}

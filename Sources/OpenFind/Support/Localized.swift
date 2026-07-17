import Foundation

/// Retrieves localized strings from the standard application Resources folder.
/// Base language is English (keys themselves are English).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .main)
}

/// Dynamic-key variant for values that come from state instead of literals.
func LD(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

import Foundation

/// Retrieves localized string from the module bundle.
/// Base language is English (keys themselves are English).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

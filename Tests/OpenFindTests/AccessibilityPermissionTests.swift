import Testing
@testable import OpenFind

@Suite("Accessibility Permission Tests")
struct AccessibilityPermissionTests {
    @Test func macOSSettingsExtensionPrecedesLegacyFallback() {
        #expect(AccessibilityPermission.settingsURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
    }
}

import ApplicationServices
import AppKit

enum AccessibilityPermission {
    static let settingsURLs = [
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!,
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
    ]

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    static func openSettings() {
        for url in settingsURLs where NSWorkspace.shared.open(url) {
            return
        }
    }
}

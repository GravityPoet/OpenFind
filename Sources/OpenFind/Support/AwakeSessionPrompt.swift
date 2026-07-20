import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum AwakeSessionPrompt {
    static func customDuration() -> TimeInterval? {
        duration(
            message: L("Custom Awake Duration"),
            confirmation: L("Start Awake Session")
        )
    }

    static func customExtension() -> TimeInterval? {
        duration(
            message: L("Extend Awake Session"),
            confirmation: L("Extend Awake Session")
        )
    }

    private static func duration(message: String, confirmation: String) -> TimeInterval? {
        let valueField = NSTextField(string: "60")
        valueField.alignment = .right
        valueField.frame.size.width = 90
        valueField.setAccessibilityLabel(L("Duration Minutes"))

        let label = NSTextField(labelWithString: L("Minutes"))
        let row = NSStackView(views: [valueField, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = L("Enter a duration greater than zero and no longer than 24 hours.")
        alert.accessoryView = row
        alert.addButton(withTitle: confirmation)
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = valueField
        guard alert.runModal() == .alertFirstButtonReturn,
              let minutes = Double(valueField.stringValue),
              minutes.isFinite,
              minutes > 0,
              minutes <= 24 * 60 else {
            return nil
        }
        return minutes * 60
    }

    static func endDate() -> Date? {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = Date().addingTimeInterval(1)
        picker.dateValue = Date().addingTimeInterval(60 * 60)
        picker.frame.size = NSSize(width: 240, height: 28)
        picker.setAccessibilityLabel(L("Awake End Date"))

        let alert = NSAlert()
        alert.messageText = L("Awake Until Date")
        alert.informativeText = L("Choose a future date and time for the session to end.")
        alert.accessoryView = picker
        alert.addButton(withTitle: L("Start Awake Session"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              picker.dateValue > Date() else { return nil }
        return picker.dateValue
    }

    static func applicationBundleIdentifier() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = L("Monitor Application")
        panel.message = L("Select a running application. The session ends when it quits.")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier,
              !identifier.isEmpty else { return nil }
        return identifier
    }
}

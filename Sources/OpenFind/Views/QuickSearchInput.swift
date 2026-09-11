import AppKit
import SwiftUI

/// The AppKit field gives a nonactivating palette an explicit first responder
/// before the first keystroke, including when a cached panel is shown again.
struct QuickSearchInput: NSViewRepresentable {
    @Binding var text: String
    let scale: CGFloat
    let onReady: (NSTextField) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        field.isSelectable = true
        field.cell?.usesSingleLineMode = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = L("Quick Search Placeholder")
        field.setAccessibilityLabel(L("Quick Search"))
        field.identifier = NSUserInterfaceItemIdentifier("OpenFind.quickSearch.query")
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        onReady(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.font = .systemFont(ofSize: 24 * scale, weight: .regular)
        if field.stringValue != text, !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

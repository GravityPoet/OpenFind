import SwiftUI

struct ClipboardHistoryFooter: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Text(String(format: L("Clipboard History Count"), store.filteredEntries.count))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if !store.query.isEmpty {
                    Text(String(format: L("Clipboard Total Count"), store.entries.count))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                ClipboardShortcutBadge(keys: "↑↓", title: L("Navigate"))
                ClipboardShortcutBadge(keys: "↩", title: L("Paste"))
                ClipboardShortcutBadge(
                    keys: store.preferences.pinShortcut.displayText,
                    title: L("Pin")
                )
                ClipboardShortcutBadge(
                    keys: store.preferences.deleteShortcut.displayText,
                    title: L("Delete")
                )
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(.regularMaterial)
    }
}

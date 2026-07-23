import SwiftUI

struct ClipboardHistoryFooter: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: L("Clipboard History Count"), store.filteredEntries.count))
                .foregroundStyle(.secondary)

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
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

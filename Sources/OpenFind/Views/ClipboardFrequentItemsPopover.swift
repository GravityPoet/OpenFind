import SwiftUI

struct ClipboardFrequentItemsPopover: View {
    @Bindable var store: ClipboardHistoryStore
    let entries: [ClipboardEntry]
    let onUse: (ClipboardEntry) -> Void
    let onHoverChange: (Bool) -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredEntryID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L("Frequently Used Section"), systemImage: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)

            Divider()

            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    frequentItemButton(entry)
                }
            }
        }
        .padding(10)
        .frame(width: 350)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .onExitCommand(perform: onDismiss)
        .onDisappear { onHoverChange(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Frequently Used Section")))
    }

    private func frequentItemButton(_ entry: ClipboardEntry) -> some View {
        Button {
            onUse(entry)
        } label: {
            HStack(spacing: 9) {
                leadingIcon(for: entry)

                VStack(alignment: .leading, spacing: 1) {
                    Text(ClipboardHighlightedText.title(
                        for: entry,
                        query: "",
                        preferences: store.preferences
                    ))
                        .font(ClipboardTypography.row)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let note = ClipboardHighlightedText.note(
                        for: entry,
                        query: "",
                        preferences: store.preferences
                    ) {
                        HStack(spacing: 3) {
                            Text(L("Clipboard Note Annotation"))
                                .fixedSize(horizontal: true, vertical: false)
                            Text(note)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(ClipboardTypography.matchContext)
                        .foregroundStyle(ClipboardTypography.noteText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: entry.hasCustomTitle ? 46 : 38)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hoveredEntryID == entry.id
                        ? Color.accentColor.opacity(0.13)
                        : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: hoveredEntryID
        )
        .accessibilityLabel(Text(entry.previewText))
        .accessibilityHint(Text(L("Press Return to Paste Clipboard Item")))
    }

    @ViewBuilder
    private func leadingIcon(for entry: ClipboardEntry) -> some View {
        if store.preferences.showApplicationIcons,
           let icon = store.applicationIcon(for: entry) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
    }
}

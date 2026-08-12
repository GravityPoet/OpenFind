import SwiftUI

struct ClipboardEntryPreview: View {
    @Bindable var store: ClipboardHistoryStore
    let onCopy: (ClipboardEntry) -> Void
    let onPaste: (ClipboardEntry) -> Void
    let onTogglePin: (ClipboardEntry) -> Void

    var body: some View {
        if let entry = store.selectedEntry {
            VStack(spacing: 0) {
                previewToolbar(for: entry)

                Divider()

                ClipboardEntryPreviewBody(
                    entry: entry,
                    previewImage: store.entryPreviewImage(for: entry)
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                ClipboardEntryMetadata(
                    entry: entry,
                    sourceApplicationIcon: store.applicationIcon(for: entry),
                    imageDimensions: store.imageDimensions(for: entry)
                )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
            }
            .background(Color.clear)
        } else {
            // The list column already explains why nothing is selected ("No
            // Clipboard History" / "No Results for …"); a second headline in
            // this column repeats the same message side by side. Keep the
            // preview column a quiet placeholder instead.
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    private func previewToolbar(for entry: ClipboardEntry) -> some View {
        HStack(spacing: 9) {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    Color.accentColor.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            Text(entry.kind.localizedTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)

            previewActionButton(
                systemImage: entry.isPinned ? "pin.slash" : "pin",
                title: entry.isPinned ? L("Unpin") : L("Pin"),
                identifier: "clipboard.preview.pin"
            ) {
                onTogglePin(entry)
            }

            previewActionButton(
                systemImage: "doc.on.doc",
                title: L("Copy"),
                identifier: "clipboard.preview.copy"
            ) {
                onCopy(entry)
            }

            Button {
                onPaste(entry)
            } label: {
                Label(L("Paste"), systemImage: "return")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(L("Paste"))
            .accessibilityIdentifier("clipboard.preview.paste")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.22))
    }

    private func previewActionButton(
        systemImage: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}

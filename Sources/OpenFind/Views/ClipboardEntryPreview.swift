import SwiftUI

struct ClipboardEntryPreview: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        if let entry = store.selectedEntry {
            VStack(spacing: 0) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
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
}

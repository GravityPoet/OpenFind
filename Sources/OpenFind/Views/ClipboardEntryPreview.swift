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
            ContentUnavailableView(
                L("No Matching Clipboard Items"),
                systemImage: "magnifyingglass",
                description: Text(L("Try Another Clipboard Search"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

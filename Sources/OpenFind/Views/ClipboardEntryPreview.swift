import SwiftUI

struct ClipboardEntryPreview: View {
    let entry: ClipboardEntry?

    var body: some View {
        if let entry {
            VStack(spacing: 0) {
                ClipboardEntryPreviewBody(entry: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                ClipboardEntryMetadata(entry: entry)
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

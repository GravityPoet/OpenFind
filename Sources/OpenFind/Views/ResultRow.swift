import SwiftUI

/// The name cell of a result row: file icon, name, and — for content hits — a
/// dimmed preview of the first matching line.
struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcon.icon(for: result.url))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .lineLimit(1)
                if let preview = result.contentPreview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

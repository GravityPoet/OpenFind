import AppKit
import SwiftUI

struct ClipboardEntryPreviewBody: View {
    let entry: ClipboardEntry

    var body: some View {
        if let image = entry.previewImage {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(18)
            }
        } else if entry.kind == .file, !entry.fileURLs.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entry.fileURLs, id: \.absoluteString) { fileURL in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fileURL.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(fileURL.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(entry.fullPreviewText)
                    .font(.system(
                        size: 14,
                        design: .default
                    ))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
        }
    }
}

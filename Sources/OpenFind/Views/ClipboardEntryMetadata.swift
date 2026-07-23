import AppKit
import SwiftUI

struct ClipboardEntryMetadata: View {
    let entry: ClipboardEntry
    let sourceApplicationIcon: NSImage?
    let imageDimensions: String?

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HStack(spacing: 7) {
                if let icon = sourceApplicationIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: entry.kind.systemImage)
                        .frame(width: 18, height: 18)
                }

                if let sourceName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(ClipboardTypography.primaryText)
                            .lineLimit(1)
                        if let sourceDetail {
                            Text(sourceDetail)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text(entry.kind.localizedTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                if let recognizedText = entry.recognizedText, !recognizedText.isEmpty {
                    Text(String(
                        format: L("Clipboard Recognized Text Count"),
                        recognizedText.count
                    ))
                    .lineLimit(1)
                }

                if let statistics = entry.textStatistics {
                    Text(String(
                        format: L("Clipboard Text Statistics"),
                        statistics.words,
                        statistics.characters
                    ))
                    .lineLimit(1)
                }

                HStack(spacing: 5) {
                    if let dimensions = imageDimensions {
                        Text(dimensions)
                        Text("·")
                    }
                    Text(entry.payloadByteCount.formatted(.byteCount(style: .file)))
                    if entry.numberOfCopies > 1 {
                        Text("·")
                        Text(String(
                            format: L("Clipboard Copy Count Compact"),
                            entry.numberOfCopies
                        ))
                    }
                }

                HStack(spacing: 4) {
                    Text(L("Last Copied"))
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                if entry.initialCopiedAt != entry.createdAt {
                    HStack(spacing: 4) {
                        Text(L("First Copied"))
                        Text(entry.initialCopiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var sourceName: String? {
        entry.sourceApplicationName ?? entry.sourceBundleIdentifier
    }

    private var sourceDetail: String? {
        guard entry.sourceApplicationName != nil else { return nil }
        return entry.sourceBundleIdentifier
    }
}

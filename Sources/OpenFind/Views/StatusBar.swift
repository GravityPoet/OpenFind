import SwiftUI

struct StatusBar: View {
    let viewModel: SearchViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }

            Text(String(format: L("%lld results"), Int64(viewModel.resultCount)))

            Text("·")
                .foregroundStyle(.secondary)

            Text(String(format: L("elapsed: %.2fs"), viewModel.elapsed))
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                if viewModel.indexStats.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
                Text(indexStatusText)
            }
            .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.secondary)

            Text(String(format: L("%lld events"), Int64(viewModel.indexStats.processedEvents)))
                .foregroundStyle(.secondary)

            if viewModel.isSearching {
                Button {
                    viewModel.cancel()
                } label: {
                    Label(L("Stop Search"), systemImage: "stop.circle")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
            }

            if viewModel.truncated {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(String(format: L("showing first %lld"), Int64(viewModel.resultCount)))
                }
                .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var indexStatusText: String {
        if viewModel.indexStats.isIndexing {
            return String(format: L("indexing %lld items"), Int64(viewModel.indexStats.indexedItems))
        }
        if viewModel.indexStats.loadedFromDisk {
            return String(format: L("index ready: %lld items cached"), Int64(viewModel.indexStats.indexedItems))
        }
        return String(format: L("index ready: %lld items"), Int64(viewModel.indexStats.indexedItems))
    }
}

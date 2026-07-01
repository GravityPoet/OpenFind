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
}

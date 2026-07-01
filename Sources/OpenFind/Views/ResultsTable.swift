import SwiftUI

/// Sortable results table: name (via `ResultRow`), location, size, date.
/// Double-click or Return opens; right-click reveals the row menu.
struct ResultsTable: View {
    let results: [SearchResult]
    @Binding var selection: Set<SearchResult.ID>
    @Binding var sortOrder: [KeyPathComparator<SearchResult>]

    var body: some View {
        Table(results, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { ResultRow(result: $0) }
                .width(min: 200, ideal: 280)

            TableColumn("Location", value: \.locationPath) { result in
                Text(result.locationPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(result.path)
            }
            .width(min: 160, ideal: 320)

            TableColumn("Size", value: \.size) { result in
                Text(result.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Date Modified", value: \.modified) { result in
                Text(result.modified, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 160)
        }
        .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
            let urls = Array(ids)
            if !urls.isEmpty {
                Button("Open") { urls.forEach(FileActions.open) }
                Button("Reveal in Finder") { FileActions.revealInFinder(urls) }
                Divider()
                Button("Copy Path") { FileActions.copyPaths(urls) }
            }
        } primaryAction: { ids in
            if let first = ids.first { FileActions.open(first) }
        }
    }
}

import SwiftUI

enum ResultMetadataDisplay {
    static func sizeText(for result: SearchResult, metadataAvailable: Bool) -> String {
        guard metadataAvailable else { return "—" }
        if result.isDirectory {
            guard result.isPackage else { return "—" }
            let packageSize = SearchIndexBuilder.packageLogicalSize(
                path: result.path,
                name: result.name,
                isDirectory: true,
                fallback: result.size,
                modifiedTime: result.modified.timeIntervalSinceReferenceDate
            )
            guard packageSize >= 4 * 1_024 else { return "—" }
            return ByteCountFormatter.string(fromByteCount: packageSize, countStyle: .file)
        }
        return ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file)
    }

    static func showsDates(metadataAvailable: Bool) -> Bool {
        metadataAvailable
    }
}

/// Sortable results table: name (via `ResultRow`), location, size, and dates.
/// Double-click or Return opens; right-click reveals the row menu.
struct ResultsTable: View {
    let results: [SearchResult]
    let metadataAvailable: Bool
    @Binding var selection: Set<SearchResult.ID>
    @Binding var sortOrder: [KeyPathComparator<SearchResult>]
    @FocusState.Binding var focusedTarget: SearchFocusTarget?
    let onQuickLook: ([URL]) -> Void
    let onMoveToTrash: ([URL]) -> Void

    var body: some View {
        Table(results, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Name"), value: \.name) { ResultRow(result: $0) }
                .width(min: 200, ideal: 280)

            TableColumn(L("Location"), value: \.locationPath) { result in
                Text(result.locationPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(result.path)
            }
            .width(min: 160, ideal: 320)

            TableColumn(L("Size"), value: \.size) { result in
                Text(ResultMetadataDisplay.sizeText(for: result, metadataAvailable: metadataAvailable))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn(L("Date Modified"), value: \.modified) { result in
                if ResultMetadataDisplay.showsDates(metadataAvailable: metadataAvailable) {
                    Text(result.modified, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 130, ideal: 160)

            TableColumn(L("Date Created"), value: \.created) { result in
                if ResultMetadataDisplay.showsDates(metadataAvailable: metadataAvailable) {
                    Text(result.created, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 130, ideal: 160)
        }
        .focused($focusedTarget, equals: .results)
        .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
            let urls = Array(ids)
            if !urls.isEmpty {
                Button(L("Open")) { urls.forEach(FileActions.open) }
                    .keyboardShortcut("o", modifiers: .command)
                Button(L("Reveal in Finder")) { FileActions.revealInFinder(urls) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button(L("Copy File Name")) { FileActions.copyFileNames(urls) }
                Button(L("Copy Path")) { FileActions.copyPaths(urls) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(L("Copy File")) { FileActions.copyFiles(urls) }
                    .keyboardShortcut("c", modifiers: .command)
                Button(L("Quick Look")) { onQuickLook(urls) }
                    .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button(L("Move to Trash"), role: .destructive) { onMoveToTrash(urls) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        } primaryAction: { ids in
            if let first = ids.first { FileActions.open(first) }
        }
        .onKeyPress(.space) {
            let urls = results.compactMap { selection.contains($0.id) ? $0.url : nil }
            guard !urls.isEmpty else { return .ignored }
            onQuickLook(urls)
            return .handled
        }
    }
}

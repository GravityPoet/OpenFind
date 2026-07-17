import SwiftUI

struct EventsTable: View {
    let events: [FileSystemEventLogEntry]
    @Binding var selection: Set<FileSystemEventLogEntry.ID>
    @Binding var sortOrder: [KeyPathComparator<FileSystemEventLogEntry>]

    var body: some View {
        Table(events, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("Time"), value: \.receivedAt) { event in
                Text(event.receivedAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 170, ideal: 190)

            TableColumn(L("Event"), value: \.sortKey) { event in
                let eventText = event.localizedEventKeys.map(LD).joined(separator: " · ")
                Text(eventText)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .help(eventText)
            }
            .width(min: 160, ideal: 220)

            TableColumn(L("Filename"), value: \.name) { event in
                Text(event.name)
                    .lineLimit(1)
                    .help(event.normalizedPath)
            }
            .width(min: 180, ideal: 280)

            TableColumn(L("Path"), value: \.locationPath) { event in
                Text(event.locationPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(event.normalizedPath)
            }
            .width(min: 260, ideal: 520)
        }
        .contextMenu(forSelectionType: FileSystemEventLogEntry.ID.self) { ids in
            let paths = selectedPaths(for: ids)
            if !paths.isEmpty {
                Button(L("Open")) { paths.forEach { FileActions.open(URL(fileURLWithPath: $0)) } }
                Button(L("Reveal in Finder")) {
                    FileActions.revealInFinder(paths.map { URL(fileURLWithPath: $0) })
                }
                Divider()
                Button(L("Copy Path")) { FileActions.copyPathStrings(paths) }
            }
        } primaryAction: { ids in
            if let path = selectedPaths(for: ids).first {
                FileActions.open(URL(fileURLWithPath: path))
            }
        }
    }

    private func selectedPaths(for ids: Set<FileSystemEventLogEntry.ID>) -> [String] {
        events
            .filter { ids.contains($0.id) }
            .compactMap { event in
                let path = event.normalizedPath
                return path.isEmpty ? nil : path
            }
    }
}

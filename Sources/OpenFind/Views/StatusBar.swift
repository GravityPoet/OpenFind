import SwiftUI

enum SearchElapsedDisplay: Equatable {
    case milliseconds(Int)
    case secondsTenths(Int)

    static func value(for elapsed: TimeInterval) -> SearchElapsedDisplay {
        let clamped = max(0, elapsed)
        if clamped < 1 {
            return .milliseconds(min(999, Int((clamped * 1_000).rounded())))
        }
        return .secondsTenths(Int((clamped * 10).rounded()))
    }

    var localizedString: String {
        switch self {
        case .milliseconds(let value):
            return String(format: L("Search Duration Milliseconds Format"), Int64(value))
        case .secondsTenths(let value):
            return String(format: L("Search Duration Seconds Format"), Double(value) / 10)
        }
    }
}

enum IndexStatusPhase: Equatable {
    case ready
    case updating
    case enriching
    case refreshing

    static func resolve(
        isManualRefreshInFlight: Bool,
        stats: SearchIndexStats
    ) -> IndexStatusPhase {
        if stats.isMetadataEnriching { return .enriching }
        if isManualRefreshInFlight { return .refreshing }
        if stats.isIndexing { return .updating }
        return .ready
    }

    var fullLocalizationKey: String.LocalizationValue {
        switch self {
        case .ready: "Ready"
        case .updating: "Updating"
        case .enriching: "Searchable, enriching details"
        case .refreshing: "Refreshing"
        }
    }

    var compactLocalizationKey: String.LocalizationValue {
        switch self {
        case .ready: "Ready Compact"
        case .updating: "Updating Compact"
        case .enriching: "Enriching Compact"
        case .refreshing: "Refreshing Compact"
        }
    }
}

struct StatusBar: View {
    let viewModel: SearchViewModel
    @State private var showFileDetails = false
    @State private var showEventDetails = false

    var body: some View {
        OpenFindGlassContainer {
            HStack(spacing: 8) {
                statusBadge

                statPill(
                    title: L("Files"),
                    value: formattedNumber(viewModel.indexStats.indexedFiles),
                    tint: .green,
                    isSelected: viewModel.displayMode == .files
                ) {
                    showEventDetails = false
                    if viewModel.displayMode == .files {
                        showFileDetails.toggle()
                    } else {
                        viewModel.showFiles()
                    }
                }
                .popover(isPresented: $showFileDetails) {
                    fileDetails
                }

                statPill(
                    title: L("Events"),
                    value: formattedNumber(viewModel.indexStats.processedEvents),
                    tint: .orange,
                    isSelected: viewModel.displayMode == .events
                ) {
                    showFileDetails = false
                    if viewModel.displayMode == .events {
                        showEventDetails.toggle()
                    } else {
                        viewModel.showEvents()
                    }
                }
                .popover(isPresented: $showEventDetails) {
                    eventDetails
                }

                iconButton(
                    viewModel.isManualRefreshInFlight ? L("Refreshing Index") : L("Refresh Index"),
                    systemImage: viewModel.isManualRefreshInFlight ? "hourglass" : "arrow.clockwise"
                ) {
                    viewModel.refreshIndexNow()
                }
                .disabled(viewModel.isManualRefreshInFlight)
                .help(L("Refresh Index Help"))

                iconButton(L("Settings"), systemImage: "gearshape.fill") {
                    FileActions.openSettings()
                }

                iconButton(L("Stop Search"), systemImage: "stop.circle.fill") {
                    viewModel.cancel()
                }
                .opacity(viewModel.isSearching ? 1 : 0)
                .disabled(!viewModel.isSearching)
                .accessibilityHidden(!viewModel.isSearching)

                Spacer(minLength: 12)

                if !viewModel.hasFullDiskAccess {
                    Button {
                        FileActions.openSystemPrivacySettings()
                    } label: {
                        Label(L("Full Disk Access disabled"), systemImage: "lock.shield.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }

                if viewModel.hasMoreResults && !viewModel.isRefreshingSearchResults {
                    Button {
                        viewModel.showMoreResults()
                    } label: {
                        if viewModel.isExpandingResults {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text(L("Loading Results"))
                            }
                        } else {
                            Label(
                                String(
                                    format: L("Show %lld More Results"),
                                    Int64(viewModel.nextResultPageCount)
                                ),
                                systemImage: "chevron.down.circle"
                            )
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .disabled(viewModel.isExpandingResults)
                    .frame(width: 180, alignment: .trailing)
                }

                Text(searchSummary)
                    .lineLimit(1)
                    .monospacedDigit()
                    .frame(width: 300, alignment: .trailing)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .openFindGlassRectangle()
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Group {
                if viewModel.indexStats.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 14, height: 14)

            // Reserve only the widest localized state label. This keeps the
            // following pills anchored without an oversized fixed slot.
            ZStack(alignment: .leading) {
                Text(L("Ready Compact"))
                    .hidden()
                    .accessibilityHidden(true)
                Text(L("Updating Compact"))
                    .hidden()
                    .accessibilityHidden(true)
                Text(L("Refreshing Compact"))
                    .hidden()
                    .accessibilityHidden(true)
                Text(L("Enriching Compact"))
                    .hidden()
                    .accessibilityHidden(true)
                Text(compactIndexStatusText)
            }
            .fontWeight(.semibold)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.9)
            .fixedSize(horizontal: true, vertical: false)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .padding(.vertical, 5)
        .help(backgroundSyncHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indexStatusText)
    }

    private var fileDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Index Details"), systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            detailRow(L("Files"), formattedNumber(viewModel.indexStats.indexedFiles))
            detailRow(L("Folders"), formattedNumber(viewModel.indexStats.indexedDirectories))
            detailRow(L("Total Indexed"), formattedNumber(viewModel.indexStats.indexedItems))
            if viewModel.indexStats.unavailablePaths > 0 {
                detailRow(
                    L("Unavailable Paths"),
                    formattedNumber(viewModel.indexStats.unavailablePaths)
                )
            }
            detailRow(L("Index Mode"), viewModel.options.deepIndex ? L("Deep Index") : L("Normal Index"))
            detailRow(L("Hidden Files"), viewModel.options.includeHidden ? L("Included") : L("Excluded"))
            detailRow(L("Index Source"), viewModel.indexStats.loadedFromDisk ? L("Cache") : L("Live Scan"))

            Divider()

            Text(scopeSummary)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.indexStats.unavailablePaths > 0 {
                Divider()

                Label(L("Background Sync"), systemImage: "arrow.triangle.2.circlepath")
                    .fontWeight(.semibold)

                Text(backgroundSyncHelp)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if viewModel.unavailablePaths.isEmpty {
                    Text(L("Background Sync Paths Pending"))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(viewModel.unavailablePaths, id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .padding(14)
        .frame(
            width: viewModel.indexStats.unavailablePaths > 0 ? 380 : 300,
            alignment: .leading
        )
    }

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("File System Events"), systemImage: "waveform.path.ecg")
                .font(.headline)

            detailRow(L("Processed Events"), formattedNumber(viewModel.indexStats.processedEvents))
            detailRow(L("Current Index Status"), indexStatusText)

            Text(eventAdvice)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showEventDetails = false
                viewModel.refreshIndexNow()
            } label: {
                Label(
                    viewModel.isManualRefreshInFlight ? L("Refreshing Index") : L("Refresh Index"),
                    systemImage: viewModel.isManualRefreshInFlight ? "hourglass" : "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isManualRefreshInFlight)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    private func statPill(
        title: String,
        value: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 36, alignment: .trailing)
                Text(value)
                    .fontWeight(.bold)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 66, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? tint.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private var searchSummary: AttributedString {
        let markdown: String
        if viewModel.displayMode == .events {
            markdown = String(
                format: L("Event Summary Styled Format"),
                formattedNumber(viewModel.filteredEventEntries.count),
                formattedNumber(viewModel.eventEntries.count)
            )
        } else if viewModel.isRefreshingSearchResults {
            markdown = String(
                format: L("Search Summary Refreshing Styled Format"),
                formattedNumber(viewModel.resultCount),
                formattedNumber(viewModel.totalResultCount)
            )
        } else {
            let duration = SearchElapsedDisplay.value(for: viewModel.elapsed).localizedString
            markdown = String(
                format: viewModel.isSearching
                    ? L("Searching Summary Styled Paged Format")
                    : L("Search Summary Styled Paged Format"),
                formattedNumber(viewModel.resultCount),
                formattedNumber(viewModel.totalResultCount),
                duration
            )
        }

        var attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        attributed.foregroundColor = .secondary
        let emphasizedRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? run.range : nil
        }
        for (index, range) in emphasizedRanges.enumerated() {
            if viewModel.displayMode == .events {
                attributed[range].foregroundColor = index == 0 ? .orange : .primary
            } else {
                switch index {
                case 0:
                    attributed[range].foregroundColor = .green
                case 1:
                    attributed[range].foregroundColor = .primary
                default:
                    attributed[range].foregroundColor = Color.accentColor
                }
            }
        }
        return attributed
    }

    private var eventAdvice: String {
        if viewModel.indexStats.unavailablePaths > 0 {
            return backgroundSyncHelp
        }
        if viewModel.indexStats.processedEvents == 0 {
            return L("No file-system changes have been processed for this index yet.")
        }
        return L("If results look stale or the event count is high, run a full refresh to rebuild the local index.")
    }

    private var indexStatusText: String {
        L(indexStatusPhase.fullLocalizationKey)
    }

    private var compactIndexStatusText: String {
        L(indexStatusPhase.compactLocalizationKey)
    }

    private var indexStatusPhase: IndexStatusPhase {
        IndexStatusPhase.resolve(
            isManualRefreshInFlight: viewModel.isManualRefreshInFlight,
            stats: viewModel.indexStats
        )
    }

    private var backgroundSyncHelp: String {
        if viewModel.indexStats.isMetadataEnriching {
            return L("Names and paths are ready to search while OpenFind enriches file details in the background.")
        }
        guard viewModel.indexStats.unavailablePaths > 0 else { return L("Index is ready") }
        return String(
            format: L("Background Sync Help Format"),
            Int64(viewModel.indexStats.unavailablePaths)
        )
    }

    private var scopeSummary: String {
        if SearchScopes.isWholeMacOnly(viewModel.scopes) {
            return L("Scope Detail Whole Mac")
        }
        let names = viewModel.scopes.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        return String(format: L("Scope Detail Format"), names)
    }

    private func formattedNumber(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

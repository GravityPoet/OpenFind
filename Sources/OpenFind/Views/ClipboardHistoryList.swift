import AppKit
import SwiftUI

struct ClipboardHistoryList: View {
    @Bindable var store: ClipboardHistoryStore
    let onUse: (ClipboardEntry) -> Void
    let onCopy: (ClipboardEntry) -> Void
    let onPaste: (ClipboardEntry) -> Void
    let onPastePlainText: (ClipboardEntry) -> Void
    let onEditNote: (ClipboardEntry) -> Void
    let onToggleFrequentlyUsed: (ClipboardEntry) -> Void
    let onPin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    @State private var selectionOrigin = SelectionOrigin.other

    var body: some View {
        let visibleEntries = store.filteredEntries
        let highlightQuery = store.highlightQuery
        let annotatedEntries = Self.annotate(
            visibleEntries,
            isSearching: !store.query.isEmpty,
            copiedDate: { entry in
                store.preferences.sortMode == .lastCopied
                    ? entry.createdAt
                    : entry.initialCopiedAt
            }
        )
        ScrollViewReader { proxy in
            Group {
                if visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: store.query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(annotatedEntries, id: \.entry.id) { item in
                                if let sectionTitle = item.sectionTitle {
                                    ClipboardSectionHeader(title: sectionTitle)
                                }
                                let entry = item.entry
                                let index = store.visibleIndex(for: entry) ?? 0
                                ClipboardHistoryRow(
                                    entry: entry,
                                    previewImage: store.rowPreviewImage(for: entry),
                                    sourceApplicationIcon: store.applicationIcon(for: entry),
                                    quickIndex: store.quickIndex(for: entry),
                                    selectionOrder: store.selectionOrder(for: entry),
                                    searchPresentation: store.searchPresentation(for: entry),
                                    isSelected: index == store.selectedIndex
                                        || store.selectionOrder(for: entry) != nil,
                                    query: highlightQuery,
                                    preferences: store.preferences,
                                    canUsePlainText: store.canCopyPlainText(entry),
                                    isFrequentlyUsed: entry.frequentOverride == true
                                        || store.isFrequentlyUsed(entry),
                                    onUse: {
                                        let modifiers = NSEvent.modifierFlags.intersection([
                                            .command, .control, .option, .shift,
                                        ])
                                        if modifiers == .command {
                                            store.toggleMultiSelection(entry)
                                            return
                                        }
                                        if modifiers == .shift {
                                            store.selectRange(to: entry)
                                            return
                                        }
                                        if modifiers == .option {
                                            store.select(entry)
                                            onPaste(entry)
                                            return
                                        }
                                        if modifiers == [.option, .shift] {
                                            store.select(entry)
                                            onPastePlainText(entry)
                                            return
                                        }
                                        let startsStack = store.multiSelectionCount > 1
                                            && store.selectedEntryIDs.contains(entry.id)
                                        if startsStack {
                                            store.selectedIndex = index
                                        } else {
                                            store.select(entry)
                                        }
                                        onUse(entry)
                                    },
                                    onHoverSelection: {
                                        let previousIndex = store.selectedIndex
                                        selectionOrigin = .pointer
                                        store.select(entry, preservingMultiSelection: true)
                                        if store.selectedIndex == previousIndex {
                                            selectionOrigin = .other
                                        }
                                    },
                                    onCopy: { onCopy(entry) },
                                    onPaste: { onPaste(entry) },
                                    onPastePlainText: { onPastePlainText(entry) },
                                    onEditNote: {
                                        store.select(entry)
                                        onEditNote(entry)
                                    },
                                    onToggleFrequentlyUsed: {
                                        store.select(entry)
                                        onToggleFrequentlyUsed(entry)
                                    },
                                    onPin: {
                                        store.select(entry)
                                        onPin(entry)
                                    },
                                    onDelete: {
                                        store.select(entry)
                                        onDelete(entry)
                                    }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 7)
                    }
                }
            }
            .onChange(of: store.selectedIndex) {
                if selectionOrigin == .pointer {
                    selectionOrigin = .other
                    return
                }
                guard let selected = store.selectedEntry else { return }
                proxy.scrollTo(selected.id)
            }
        }
        .background(Color.clear)
    }

    private struct AnnotatedEntry {
        let sectionTitle: String?
        let entry: ClipboardEntry
    }

    private enum SectionKey {
        case pinned, otherResults, today, yesterday, week, earlier

        var title: String {
            switch self {
            case .pinned: L("Pinned Section")
            case .otherResults: L("Other Results Section")
            case .today: L("Today Section")
            case .yesterday: L("Yesterday Section")
            case .week: L("Previous Week Section")
            case .earlier: L("Earlier Section")
            }
        }
    }

    private static func annotate(
        _ entries: [ClipboardEntry],
        isSearching: Bool,
        copiedDate: (ClipboardEntry) -> Date
    ) -> [AnnotatedEntry] {
        if isSearching, !entries.contains(where: \.isPinned) {
            return entries.map { AnnotatedEntry(sectionTitle: nil, entry: $0) }
        }
        let calendar = Calendar.current
        let weekCutoff = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        var previousKey: SectionKey?
        return entries.map { entry in
            let key: SectionKey
            if isSearching {
                key = entry.isPinned ? .pinned : .otherResults
            } else if entry.isPinned {
                key = .pinned
            } else if calendar.isDateInToday(copiedDate(entry)) {
                key = .today
            } else if calendar.isDateInYesterday(copiedDate(entry)) {
                key = .yesterday
            } else if copiedDate(entry) > weekCutoff {
                key = .week
            } else {
                key = .earlier
            }
            defer { previousKey = key }
            return AnnotatedEntry(
                sectionTitle: key == previousKey ? nil : key.title,
                entry: entry
            )
        }
    }

}

private struct ClipboardSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

private enum SelectionOrigin {
    case pointer
    case other
}

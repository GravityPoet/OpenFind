import AppKit
import SwiftUI

struct ClipboardHistoryList: View {
    @Bindable var store: ClipboardHistoryStore
    let onUse: (ClipboardEntry) -> Void
    let onCopy: (ClipboardEntry) -> Void
    let onPaste: (ClipboardEntry) -> Void
    let onPastePlainText: (ClipboardEntry) -> Void
    let onPin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    @State private var selectionOrigin = SelectionOrigin.other

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if store.filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: store.query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(
                                Array(store.filteredEntries.enumerated()),
                                id: \.element.id
                            ) { index, entry in
                                ClipboardHistoryRow(
                                    entry: entry,
                                    quickIndex: quickIndex(for: entry),
                                    selectionOrder: store.selectionOrder(for: entry),
                                    isSelected: index == store.selectedIndex
                                        || store.selectionOrder(for: entry) != nil,
                                    query: store.query,
                                    preferences: store.preferences,
                                    canUsePlainText: store.canCopyPlainText(entry),
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

    private func quickIndex(for entry: ClipboardEntry) -> Int? {
        guard !entry.isPinned else { return nil }
        let unpinned = store.filteredEntries.filter { !$0.isPinned }
        guard let index = unpinned.firstIndex(where: { $0.id == entry.id }),
              index < 9 else { return nil }
        return index + 1
    }
}

private enum SelectionOrigin {
    case pointer
    case other
}

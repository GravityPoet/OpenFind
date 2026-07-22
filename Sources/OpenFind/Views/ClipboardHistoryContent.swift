import SwiftUI

struct ClipboardHistoryContent: View {
    @Bindable var store: ClipboardHistoryStore
    let onUse: (ClipboardEntry) -> Void
    let onCopy: (ClipboardEntry) -> Void
    let onPaste: (ClipboardEntry) -> Void
    let onPastePlainText: (ClipboardEntry) -> Void
    let onPin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void

    var body: some View {
        if store.requiresPersistenceMigration {
            migrationView
        } else if store.entries.isEmpty {
            ContentUnavailableView(
                L("No Clipboard History"),
                systemImage: "doc.on.clipboard",
                description: Text(L("Copy Something to Build History"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if store.isPreviewVisible {
                HSplitView {
                    historyList
                        .frame(minWidth: 310, idealWidth: 350, maxWidth: 410)

                    ClipboardEntryPreview(entry: store.selectedEntry)
                        .frame(
                            minWidth: 300,
                            idealWidth: store.preferences.previewWidth,
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onChange(of: proxy.size.width) {
                                        retainPreviewWidth(proxy.size.width)
                                    }
                            }
                        }
                }
            } else {
                historyList
            }
        }
    }

    private var historyList: some View {
        ClipboardHistoryList(
            store: store,
            onUse: onUse,
            onCopy: onCopy,
            onPaste: onPaste,
            onPastePlainText: onPastePlainText,
            onPin: onPin,
            onDelete: onDelete
        )
    }

    private var migrationView: some View {
        ContentUnavailableView {
            Label(L("Clipboard Migration Required"), systemImage: "key.fill")
        } description: {
            Text(L("Clipboard Migration Help"))
        } actions: {
            Button(L("Unlock and Migrate Clipboard History")) {
                store.migratePersistence()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retainPreviewWidth(_ width: CGFloat) {
        guard (260...800).contains(width),
              abs(store.preferences.previewWidth - width) >= 4 else { return }
        store.setPreference(\.previewWidth, to: width)
    }
}

import SwiftUI

struct ClipboardPinsSettings: View {
    @Bindable var store: ClipboardHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Pinned Clipboard Items"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            if pinnedEntries.isEmpty {
                ContentUnavailableView(
                    L("No Pinned Clipboard Items"),
                    systemImage: "pin"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pinnedEntries) { entry in
                            ClipboardPinEditorRow(store: store, entryID: entry.id)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            Text(L("Pinned Clipboard Items Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(width: 680, height: 430)
    }

    private var pinnedEntries: [ClipboardEntry] {
        store.entries.filter(\.isPinned).sorted {
            $0.initialCopiedAt > $1.initialCopiedAt
        }
    }
}

private struct ClipboardPinEditorRow: View {
    @Bindable var store: ClipboardHistoryStore
    let entryID: UUID

    var body: some View {
        if let entry {
            HStack(spacing: 10) {
                Picker(L("Pinned Item Key"), selection: pinBinding(entry)) {
                    ForEach(pinOptions(for: entry), id: \.self) { key in
                        Text(key.uppercased()).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 62)

                TextField(L("Pinned Item Alias"), text: titleBinding(entry))
                    .frame(minWidth: 150)

                if isTextEditable(entry) {
                    TextField(L("Pinned Item Content"), text: contentBinding(entry))
                        .frame(maxWidth: .infinity)
                } else {
                    Text(L("Pinned Item Content Is Not Editable"))
                        .foregroundStyle(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    store.togglePinned(entry)
                } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .help(L("Unpin"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private var entry: ClipboardEntry? {
        store.entries.first(where: { $0.id == entryID })
    }

    private func pinOptions(for entry: ClipboardEntry) -> [String] {
        Array(Set(store.availablePinKeys(excluding: entry) + [entry.pinKey].compactMap { $0 }))
            .sorted()
    }

    private func pinBinding(_ entry: ClipboardEntry) -> Binding<String> {
        Binding(
            get: { self.entry?.pinKey ?? entry.pinKey ?? "" },
            set: { _ = store.setPinKey($0, for: entry) }
        )
    }

    private func titleBinding(_ entry: ClipboardEntry) -> Binding<String> {
        Binding(
            get: { self.entry?.customTitle ?? "" },
            set: { store.setCustomTitle($0, for: entry) }
        )
    }

    private func contentBinding(_ entry: ClipboardEntry) -> Binding<String> {
        Binding(
            get: { self.entry?.previewText ?? entry.previewText },
            set: { _ = store.setPlainText($0, for: entry) }
        )
    }

    private func isTextEditable(_ entry: ClipboardEntry) -> Bool {
        [.text, .richText, .url].contains(entry.kind)
    }
}

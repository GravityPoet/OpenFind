import SwiftUI

struct ClipboardStorageSettings: View {
    @Bindable var store: ClipboardHistoryStore
    @State private var showingPinnedItems = false

    var body: some View {
        LabeledContent(L("Clipboard Retained Types")) {
            HStack(spacing: 12) {
                ForEach(ClipboardStorageCategory.allCases, id: \.self) { category in
                    Toggle(category.localizedTitle, isOn: categoryBinding(category))
                        .toggleStyle(.checkbox)
                }
            }
        }

        Picker(L("Clipboard Retention"), selection: Binding(
            get: { store.retentionPeriod },
            set: { store.setRetentionPeriod($0) }
        )) {
            ForEach(ClipboardRetentionPeriod.allCases) { period in
                Text(period.localizedTitle).tag(period)
            }
        }
        Text(L("Clipboard Retention Help"))
            .font(.footnote)
            .foregroundStyle(.secondary)

        if store.preferences.enabledStorageCategories.contains(.images) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    L("Search Text Inside Clipboard Images"),
                    isOn: Binding(
                        get: { store.preferences.imageTextRecognitionEnabled },
                        set: { store.setImageTextRecognitionEnabled($0) }
                    )
                )
                Text(L("Clipboard Image Text Recognition Help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Picker(L("Clipboard Item Size Limit"), selection: Binding(
            get: { store.itemLimitBytes / (1_024 * 1_024) },
            set: { store.setItemLimitMegabytes($0) }
        )) {
            ForEach([1, 2, 4, 8, 16], id: \.self) { megabytes in
                Text("\(megabytes) MB").tag(megabytes)
            }
        }

        LabeledContent(L("Clipboard Current Storage")) {
            Text(store.retainedStorageBytes.formatted(.byteCount(style: .file)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        Picker(L("Clipboard Sort Order"), selection: Binding(
            get: { store.preferences.sortMode },
            set: { store.setSortMode($0) }
        )) {
            ForEach(ClipboardSortMode.allCases) { mode in
                Text(mode.localizedTitle).tag(mode)
            }
        }

        Picker(L("Clipboard Pins Position"), selection: Binding(
            get: { store.preferences.pinsPosition },
            set: { store.setPinsPosition($0) }
        )) {
            ForEach(ClipboardPinsPosition.allCases) { position in
                Text(position.localizedTitle).tag(position)
            }
        }

        Button {
            showingPinnedItems = true
        } label: {
            HStack {
                Text(L("Manage Reusable Snippets"))
                Spacer()
                Text(store.entries.filter(\.isPinned).count.formatted())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPinnedItems) {
            ClipboardPinsSettings(store: store)
        }
    }

    private func categoryBinding(_ category: ClipboardStorageCategory) -> Binding<Bool> {
        Binding(
            get: { store.preferences.enabledStorageCategories.contains(category) },
            set: { store.setStorageCategory(category, enabled: $0) }
        )
    }
}

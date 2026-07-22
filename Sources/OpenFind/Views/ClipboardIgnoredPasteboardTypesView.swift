import SwiftUI

struct ClipboardIgnoredPasteboardTypesView: View {
    @Bindable var store: ClipboardHistoryStore
    @State private var selection: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(types, id: \.self, selection: $selection) { type in
                Text(type)
                    .font(.system(.body, design: .monospaced))
                    .tag(type)
            }

            HStack(spacing: 8) {
                TextField(L("Clipboard Pasteboard Type Placeholder"), text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addType() }
                Button(L("Add")) { addType() }
                    .disabled(normalizedDraft.isEmpty)
                Button {
                    removeSelection()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Button(L("Reset")) { store.resetIgnoredPasteboardTypes() }
            }

            Text(L("Clipboard Pasteboard Types Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var types: [String] {
        store.preferences.ignoredPasteboardTypes.sorted()
    }

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addType() {
        guard !normalizedDraft.isEmpty else { return }
        store.setIgnoredPasteboardTypes(
            store.preferences.ignoredPasteboardTypes.union([normalizedDraft])
        )
        selection = normalizedDraft
        draft = ""
    }

    private func removeSelection() {
        guard let selection else { return }
        store.setIgnoredPasteboardTypes(
            store.preferences.ignoredPasteboardTypes.subtracting([selection])
        )
        self.selection = nil
    }
}

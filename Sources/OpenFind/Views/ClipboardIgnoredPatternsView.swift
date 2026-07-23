import Foundation
import SwiftUI

struct ClipboardIgnoredPatternsView: View {
    @Bindable var store: ClipboardHistoryStore
    @State private var selection: String?
    @State private var draft = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L("Clipboard Text Filters Explanation"),
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if patterns.isEmpty {
                ContentUnavailableView(
                    L("No Clipboard Text Filters"),
                    systemImage: "text.magnifyingglass",
                    description: Text(L("No Clipboard Text Filters Help"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(patterns, id: \.self, selection: $selection) { pattern in
                    Text(pattern)
                        .font(.system(.body, design: .monospaced))
                        .tag(pattern)
                }
            }

            HStack(spacing: 8) {
                TextField(L("Clipboard Ignore Pattern Placeholder"), text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addPattern() }
                Button(L("Add")) { addPattern() }
                    .disabled(normalizedDraft.isEmpty)
                Button {
                    removeSelection()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text(L("Clipboard Ignore Patterns Help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var patterns: [String] { store.preferences.ignoredTextPatterns }

    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addPattern() {
        let pattern = normalizedDraft
        guard !pattern.isEmpty else { return }
        guard pattern.count <= 512,
              (try? NSRegularExpression(pattern: pattern)) != nil else {
            validationMessage = L("Clipboard Invalid Ignore Pattern")
            return
        }
        store.setIgnoredTextPatterns(patterns + [pattern])
        selection = pattern
        draft = ""
        validationMessage = nil
    }

    private func removeSelection() {
        guard let selection else { return }
        store.setIgnoredTextPatterns(patterns.filter { $0 != selection })
        self.selection = nil
        validationMessage = nil
    }
}

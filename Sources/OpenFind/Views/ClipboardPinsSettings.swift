import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPinsSettings: View {
    @Bindable var store: ClipboardHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var draft = ClipboardSnippetDraft()
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                snippetList
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 310)
                editor
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 560)
        .onAppear {
            selectedID = selectedID ?? store.reusableEntries.first?.id
            loadDraft()
        }
        .onChange(of: selectedID) { loadDraft() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(L("Reusable Snippets"))
                .font(.title3.weight(.semibold))
            Text(store.reusableEntries.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Spacer()
            Button(action: createSnippet) {
                Label(L("New Snippet"), systemImage: "plus")
            }
            Button(action: importArchive) {
                Label(L("Import Snippets"), systemImage: "square.and.arrow.down")
            }
            Button(action: exportArchive) {
                Label(L("Export Snippets"), systemImage: "square.and.arrow.up")
            }
            .disabled(store.reusableEntries.isEmpty)
            Button(L("Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var snippetList: some View {
        List(selection: $selectedID) {
            ForEach(groupedEntries, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.expandsFromKeyword
                                ? "text.badge.checkmark" : "text.quote")
                                .foregroundStyle(entry.expandsFromKeyword ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayTitle)
                                    .lineLimit(1)
                                if let keyword = entry.snippetKeyword {
                                    Text(keyword)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .tag(entry.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.reusableEntries.isEmpty {
                ContentUnavailableView(
                    L("No Reusable Snippets"),
                    systemImage: "text.quote",
                    description: Text(L("No Reusable Snippets Help"))
                )
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        TextField(L("Snippet Name"), text: $draft.name)
                            .font(.title3.weight(.medium))
                        Picker(L("Pinned Item Key"), selection: $draft.pinKey) {
                            Text("—").tag("")
                            ForEach(pinOptions(for: entry), id: \.self) { key in
                                Text("⌘\(key.uppercased())").tag(key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 82)
                    }

                    if store.canCopyPlainText(entry) {
                        HStack(spacing: 12) {
                            LabeledContent(L("Snippet Collection")) {
                                TextField(L("Snippet Collection Placeholder"), text: $draft.collection)
                                    .textFieldStyle(.roundedBorder)
                            }
                            LabeledContent(L("Snippet Keyword")) {
                                TextField(L("Snippet Keyword Placeholder"), text: $draft.keyword)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospaced())
                            }
                        }

                        Toggle(L("Expand Snippet Automatically"), isOn: $draft.expandsAutomatically)
                            .disabled(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Snippet Content"))
                                .font(.headline)
                            TextEditor(text: $draft.content)
                                .font(.body.monospaced())
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 210)
                                .background(.quaternary.opacity(0.48), in: RoundedRectangle(
                                    cornerRadius: 10,
                                    style: .continuous
                                ))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.separator.opacity(0.45), lineWidth: 0.7)
                                }
                        }

                        Text(L("Snippet Placeholder Help"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        ContentUnavailableView(
                            L("Snippet Text Only"),
                            systemImage: entry.kind.systemImage,
                            description: Text(L("Pinned Item Content Is Not Editable"))
                        )
                        .frame(minHeight: 280)
                    }

                    HStack {
                        Button(L("Remove from Reusable Items"), role: .destructive) {
                            store.togglePinned(entry)
                            selectedID = store.reusableEntries.first?.id
                        }
                        Spacer()
                        Button(L("Save Snippet Changes"), action: saveDraft)
                            .buttonStyle(.borderedProminent)
                            .disabled(!isDraftDirty)
                    }
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView(
                L("Select a Snippet"),
                systemImage: "text.quote"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "lock.shield")
                .foregroundStyle(isError ? Color.orange : .secondary)
            Text(message ?? L("Snippet Export Privacy Help"))
                .font(.footnote)
                .foregroundStyle(isError ? Color.primary : .secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var selectedEntry: ClipboardEntry? {
        guard let selectedID else { return nil }
        return store.entries.first { $0.id == selectedID && $0.isPinned }
    }

    private var groupedEntries: [(name: String, entries: [ClipboardEntry])] {
        let entries = store.reusableEntries
        let groups = Dictionary(grouping: entries) {
            $0.snippetCollection ?? L("Unfiled Snippets")
        }
        return groups.map { (name: $0.key, entries: $0.value) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var isDraftDirty: Bool {
        guard let entry = selectedEntry else { return false }
        return draft != ClipboardSnippetDraft(entry: entry, content: store.plainText(for: entry) ?? "")
    }

    private func pinOptions(for entry: ClipboardEntry) -> [String] {
        Array(Set(store.availablePinKeys(excluding: entry) + [entry.pinKey].compactMap { $0 }))
            .sorted()
    }

    private func loadDraft() {
        guard let entry = selectedEntry else {
            draft = ClipboardSnippetDraft()
            return
        }
        draft = ClipboardSnippetDraft(entry: entry, content: store.plainText(for: entry) ?? "")
        message = nil
        isError = false
    }

    private func createSnippet() {
        do {
            let entry = try store.createSnippet(
                name: L("New Snippet"),
                content: ""
            )
            selectedID = entry.id
            message = L("Snippet Created")
            isError = false
        } catch {
            show(error)
        }
    }

    private func saveDraft() {
        guard let entry = selectedEntry else { return }
        do {
            try store.configureSnippet(
                entry,
                name: draft.name,
                content: draft.content,
                keyword: draft.keyword,
                collection: draft.collection,
                expandsAutomatically: draft.expandsAutomatically
            )
            if draft.pinKey != entry.pinKey, !draft.pinKey.isEmpty {
                _ = store.setPinKey(draft.pinKey, for: entry)
            }
            loadDraft()
            message = L("Snippet Changes Saved")
            isError = false
        } catch {
            show(error)
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.prompt = L("Import")
        panel.message = L("Import Snippets Help")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importSnippetArchive(Data(contentsOf: url, options: .mappedIfSafe))
            selectedID = store.reusableEntries.first?.id
            message = String(format: L("Snippets Imported Count"), count)
            isError = false
        } catch {
            show(error)
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenFind Snippets.json"
        panel.prompt = L("Export")
        panel.message = L("Export Snippets Help")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportSnippetArchive().write(to: url, options: [.atomic])
            message = L("Snippets Exported")
            isError = false
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? L("Snippet Operation Failed")
        isError = true
    }
}

private struct ClipboardSnippetDraft: Equatable {
    var name = ""
    var content = ""
    var keyword = ""
    var collection = ""
    var expandsAutomatically = false
    var pinKey = ""

    init() {}

    init(entry: ClipboardEntry, content: String) {
        name = entry.displayTitle
        self.content = content
        keyword = entry.snippetKeyword ?? ""
        collection = entry.snippetCollection ?? ""
        expandsAutomatically = entry.expandsFromKeyword
        pinKey = entry.pinKey ?? ""
    }
}

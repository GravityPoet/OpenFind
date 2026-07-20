import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @Bindable var store: ClipboardHistoryStore
    let onPaste: (ClipboardEntry, Bool) -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                TextField(L("Search Clipboard History"), text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { copySelected() }
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            if let error = store.lastErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                    Spacer()
                    Button {
                        store.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            Divider()

            if store.filteredEntries.isEmpty {
                ContentUnavailableView(
                    L("No Clipboard History"),
                    systemImage: "doc.on.clipboard",
                    description: Text(L("Copy Something to Build History"))
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(store.filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                ClipboardHistoryRow(
                                    entry: entry,
                                    isSelected: index == store.selectedIndex,
                                    onCopy: { copy(entry) },
                                    onPin: { store.togglePinned(entry) },
                                    onDelete: { store.delete(entry) }
                                )
                                .id(entry.id)
                                .onTapGesture { copy(entry) }
                            }
                        }
                    }
                    .onMoveCommand { direction in
                        moveSelection(direction)
                        if let selected = store.selectedEntry {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(selected.id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text(String(format: L("Clipboard History Count"), store.filteredEntries.count))
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Spacer()
                Button(L("Paste")) {
                    pasteSelected()
                }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(store.selectedEntry == nil)
                Button(L("Copy Plain Text")) {
                    copySelectedPlainText()
                }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(store.selectedEntry.map { !store.canCopyPlainText($0) } ?? true)
                Button(L("Clear Unpinned Clipboard")) {
                    store.clearUnpinned()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 520, height: 430)
        .onAppear { searchFocused = true }
        .onChange(of: store.query) { store.selectedIndex = 0 }
        .onKeyPress(.return, phases: [.down]) { press in
            if press.modifiers.contains([.option, .shift]) {
                pasteSelected(plainTextOnly: true)
                return .handled
            }
            if press.modifiers.contains(.option) {
                pasteSelected()
                return .handled
            }
            if press.modifiers.contains(.shift) {
                copySelectedPlainText()
                return .handled
            }
            if store.pasteAutomatically {
                pasteSelected()
            } else {
                copySelected()
            }
            return .handled
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let count = store.filteredEntries.count
        guard count > 0 else { return }
        switch direction {
        case .up:
            store.selectedIndex = max(0, store.selectedIndex - 1)
        case .down:
            store.selectedIndex = min(count - 1, store.selectedIndex + 1)
        default:
            break
        }
    }

    private func copySelected() {
        guard let selected = store.selectedEntry else { return }
        if store.pasteAutomatically {
            pasteSelected()
        } else {
            copy(selected)
        }
    }

    private func pasteSelected(plainTextOnly: Bool = false) {
        guard let selected = store.selectedEntry else { return }
        guard !plainTextOnly || store.canCopyPlainText(selected) else { return }
        onPaste(selected, plainTextOnly)
    }

    private func copySelectedPlainText() {
        guard let selected = store.selectedEntry,
              store.canCopyPlainText(selected) else { return }
        do {
            try store.copy(selected, plainTextOnly: true)
            onClose()
        } catch {
            store.reportError(error)
        }
    }

    private func copy(_ entry: ClipboardEntry) {
        do {
            try store.copy(entry)
            onClose()
        } catch {
            store.reportError(error)
        }
    }
}

private struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: iconName)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.previewText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onPin) {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(L("Pin Clipboard Item"))
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete Clipboard Item"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.previewText)
    }

    private var iconName: String {
        switch entry.kind {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .url: return "link"
        case .file: return "doc"
        case .image: return "photo"
        case .other: return "doc.on.clipboard"
        }
    }

    private var previewImage: NSImage? {
        guard entry.kind == .image else { return nil }
        let data = entry.representations["public.png"]
            ?? entry.representations["public.tiff"]
            ?? entry.representations["public.jpeg"]
        return data.flatMap(NSImage.init(data:))
    }
}

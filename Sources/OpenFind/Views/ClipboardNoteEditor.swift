import SwiftUI

struct ClipboardNoteEditRequest: Identifiable {
    let entry: ClipboardEntry

    var id: UUID { entry.id }
}

struct ClipboardNoteEditor: View {
    let entry: ClipboardEntry
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var note: String
    @FocusState private var noteFocused: Bool

    init(
        entry: ClipboardEntry,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entry = entry
        self.onSave = onSave
        self.onCancel = onCancel
        _note = State(initialValue: entry.customTitle ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.hasCustomTitle ? L("Edit Clipboard Note") : L("Add Clipboard Note"))
                    .font(.title3.weight(.semibold))
                Text(L("Clipboard Note Help"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField(L("Clipboard Note"), text: $note)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
                .onSubmit { onSave(note) }

            VStack(alignment: .leading, spacing: 5) {
                Text(L("Original Clipboard Content"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.previewText)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }

            HStack {
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { onSave(note) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear { noteFocused = true }
    }
}

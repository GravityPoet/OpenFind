import SwiftUI

struct ClipboardUndoBanner: View {
    let itemCount: Int
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(
                String(format: L("Clipboard Items Removed"), itemCount),
                systemImage: "trash"
            )
            .lineLimit(1)

            Divider()
                .frame(height: 16)

            Button(L("Undo"), action: onUndo)
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityHint(Text(L("Restore Removed Clipboard Items")))
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityLabel(Text(String(format: L("Clipboard Items Removed"), itemCount)))
    }
}

import SwiftUI

struct ClipboardPasteStackStatusView: View {
    let stack: ClipboardPasteStack
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
            Text(String(
                format: L("Clipboard Paste Stack Status Format"),
                stack.currentIndex + 1,
                stack.totalCount
            ))
            .font(.caption.weight(.medium))
            Spacer()
            Button(L("Cancel Paste Stack"), action: onCancel)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
    }
}

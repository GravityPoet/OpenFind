import SwiftUI

struct ClipboardShortcutBadge: View {
    let keys: String
    var title: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(
                    Color.primary.opacity(0.065),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
                }

            if let title {
                Text(title)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

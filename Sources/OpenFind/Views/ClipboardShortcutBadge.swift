import SwiftUI

struct ClipboardShortcutBadge: View {
    let keys: String
    var title: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if let title {
                Text(title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

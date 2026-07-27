import SwiftUI

/// One-tap content-type chips under the search field: all / text / images /
/// links / files. Quick indices, keyboard navigation, and search all operate
/// on the filtered projection automatically.
struct ClipboardKindFilterBar: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ClipboardKindFilter.allCases) { filter in
                chip(for: filter)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Kind Filter Bar")))
    }

    private func chip(for filter: ClipboardKindFilter) -> some View {
        let isOn = store.kindFilter == filter
        return Button {
            store.kindFilter = filter
        } label: {
            Text(filter.localizedTitle)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    isOn
                        ? AnyShapeStyle(Color.accentColor.opacity(0.92))
                        : AnyShapeStyle(.quaternary.opacity(0.55)),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.72))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

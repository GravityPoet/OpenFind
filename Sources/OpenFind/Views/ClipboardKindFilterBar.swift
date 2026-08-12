import SwiftUI

/// One-tap content-type chips under the search field: all / text / images /
/// links / files. Quick indices, keyboard navigation, and search all operate
/// on the filtered projection automatically.
struct ClipboardKindFilterBar: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClipboardKindFilter.allCases) { filter in
                chip(for: filter)
            }
        }
        .padding(3)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .fixedSize(horizontal: true, vertical: false)
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
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    isOn
                        ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

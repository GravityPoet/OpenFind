import SwiftUI

struct ClipboardHistoryHeader: View {
    @Bindable var store: ClipboardHistoryStore
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        OpenFindGlassContainer {
            HStack(spacing: 8) {
                searchControls

                Menu {
                    Button(L("Clear Unpinned Clipboard"), role: .destructive) {
                        store.clearUnpinned()
                    }
                    .disabled(store.entries.allSatisfy(\.isPinned))
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .openFindGlassCapsule()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Clipboard History Actions"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var searchControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L("Search Clipboard History"), text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)

            if !store.query.isEmpty {
                Button {
                    store.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear Search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36)
        .openFindInteractiveGlassRoundedRectangle(cornerRadius: 11)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !searchFocused {
                searchFocused = true
            }
        }
    }
}

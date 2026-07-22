import SwiftUI

struct ClipboardIgnoreRulesSheet: View {
    @Bindable var store: ClipboardHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                ClipboardIgnoredApplicationsView(store: store)
                    .tabItem {
                        Label(L("Ignored Clipboard Apps"), systemImage: "app.badge")
                    }
                ClipboardIgnoredPasteboardTypesView(store: store)
                    .tabItem {
                        Label(L("Clipboard Pasteboard Types"), systemImage: "list.bullet.rectangle")
                    }
                ClipboardIgnoredPatternsView(store: store)
                    .tabItem {
                        Label(L("Clipboard Ignore Patterns"), systemImage: "text.magnifyingglass")
                    }
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 430)
    }
}

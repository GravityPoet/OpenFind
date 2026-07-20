import SwiftUI

struct ClipboardSettingsSection: View {
    @Bindable var store: ClipboardHistoryStore
    @Bindable var controller: ClipboardController
    @State private var ignoredAppsText = ""

    var body: some View {
        Section {
            Toggle(L("Enable Clipboard History"), isOn: persistenceBinding)
            Picker(L("Clipboard History Limit"), selection: Binding(
                get: { store.historyLimit },
                set: { store.setHistoryLimit($0) }
            )) {
                ForEach([50, 100, 250, 500, 1_000], id: \.self) { count in
                    Text(String(format: L("Clipboard Items Format"), count)).tag(count)
                }
            }
            Picker(L("Clipboard Item Size Limit"), selection: Binding(
                get: { store.itemLimitBytes / (1_024 * 1_024) },
                set: { store.setItemLimitMegabytes($0) }
            )) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { megabytes in
                    Text("\(megabytes) MB").tag(megabytes)
                }
            }
            Toggle(
                L("Paste Automatically"),
                isOn: Binding(
                    get: { store.pasteAutomatically },
                    set: { store.setPasteAutomatically($0) }
                )
            )
            Toggle(
                L("Paste Without Formatting"),
                isOn: Binding(
                    get: { store.pasteWithoutFormatting },
                    set: { store.setPasteWithoutFormatting($0) }
                )
            )
            Toggle(
                L("Fuzzy Clipboard Search"),
                isOn: Binding(
                    get: { store.fuzzySearchEnabled },
                    set: { store.setFuzzySearchEnabled($0) }
                )
            )
            Toggle(
                L("Clear Clipboard History On Quit"),
                isOn: Binding(
                    get: { store.clearHistoryOnQuit },
                    set: { store.setClearHistoryOnQuit($0) }
                )
            )
            Toggle(
                L("Clear System Clipboard On Quit"),
                isOn: Binding(
                    get: { store.clearSystemClipboardOnQuit },
                    set: { store.setClearSystemClipboardOnQuit($0) }
                )
            )
            LabeledContent(L("Ignored Clipboard Apps")) {
                TextField(L("Bundle Identifiers"), text: $ignoredAppsText)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { saveIgnoredApps() }
            }
            Button(L("Save Ignored Apps")) { saveIgnoredApps() }
                .buttonStyle(.borderless)
            HStack(spacing: 8) {
                Toggle(
                    L("Clipboard Shortcut"),
                    isOn: Binding(
                        get: { controller.isShortcutEnabled },
                        set: { controller.setShortcutEnabled($0) }
                    )
                )
                Spacer()
                ShortcutRecorder(
                    shortcut: controller.shortcut,
                    prompt: L("Press Shortcut"),
                    accessibilityLabel: L("Clipboard Shortcut")
                ) { shortcut in
                    _ = controller.setShortcut(shortcut)
                }
                .frame(width: 112)
                if controller.shortcut != ClipboardController.defaultShortcut {
                    Button {
                        controller.resetShortcut()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Restore Default Shortcut"))
                }
            }
            switch controller.registrationState {
            case .registered:
                Label(L("Clipboard Shortcut Registered"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .conflict:
                Label(L("Clipboard Shortcut Conflicts"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Label(L("Clipboard Shortcut Unavailable"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .disabled:
                EmptyView()
            }
            Button(L("Clear Clipboard History"), role: .destructive) {
                store.clearAll()
            }
            .disabled(store.entries.isEmpty)
        } header: {
            Text(L("Clipboard History"))
        } footer: {
            Text(L("Clipboard History Help"))
        }
        .onAppear {
            ignoredAppsText = store.ignoredBundleIdentifiers.sorted().joined(separator: ", ")
        }
    }

    private var persistenceBinding: Binding<Bool> {
        Binding(
            get: { store.isPersistenceEnabled },
            set: { store.setPersistenceEnabled($0) }
        )
    }

    private func saveIgnoredApps() {
        let identifiers = Set(
            ignoredAppsText
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        store.setIgnoredBundleIdentifiers(identifiers)
        ignoredAppsText = store.ignoredBundleIdentifiers.sorted().joined(separator: ", ")
    }
}

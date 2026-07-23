import SwiftUI

struct ClipboardBehaviorSettings: View {
    @Bindable var store: ClipboardHistoryStore
    @Bindable var controller: ClipboardController
    @State private var showingAllowedApplications = false

    var body: some View {
        Toggle(
            L("Paste Without Formatting"),
            isOn: Binding(
                get: { store.pasteWithoutFormatting },
                set: { store.setPasteWithoutFormatting($0) }
            )
        )

        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                L("Enable Snippet Auto Expansion"),
                isOn: Binding(
                    get: { store.preferences.snippetExpansionEnabled },
                    set: { controller.setSnippetExpansionEnabled($0) }
                )
            )
            Text(L("Snippet Auto Expansion Privacy Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if store.preferences.snippetExpansionEnabled {
                if controller.snippetExpansion.isRunning {
                    Label(L("Snippet Auto Expansion Ready"), systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label(
                            controller.snippetExpansion.lastErrorMessage
                                ?? L("Snippet Expansion Permission Required"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        Spacer()
                        Button(L("Open Accessibility Settings")) {
                            AccessibilityPermission.openSettings()
                        }
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                L("Enable Clipboard Quick Merge"),
                isOn: Binding(
                    get: { store.preferences.quickMergeEnabled },
                    set: { controller.setQuickMergeEnabled($0) }
                )
            )
            if store.preferences.quickMergeEnabled {
                Picker(L("Quick Merge Separator"), selection: Binding(
                    get: { store.preferences.quickMergeSeparator },
                    set: { store.setQuickMergeSeparator($0) }
                )) {
                    ForEach(ClipboardQuickMergeSeparator.allCases) { separator in
                        Text(separator.localizedTitle).tag(separator)
                    }
                }
                if store.preferences.quickMergeSeparator == .custom {
                    TextField(
                        L("Quick Merge Custom Separator"),
                        text: Binding(
                            get: { store.preferences.quickMergeCustomSeparator },
                            set: { store.setQuickMergeCustomSeparator($0) }
                        )
                    )
                }
                if controller.quickMerge.isRunning {
                    Label(L("Quick Merge Ready"), systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else if let error = controller.quickMerge.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Text(L("Clipboard Quick Merge Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Picker(L("Clipboard Search Mode"), selection: Binding(
            get: { store.searchMode },
            set: { store.setSearchMode($0) }
        )) {
            ForEach(ClipboardSearchMode.allCases) { mode in
                Text(mode.localizedTitle).tag(mode)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Picker(L("Clipboard Check Interval"), selection: Binding(
                get: { store.clipboardCheckInterval },
                set: { controller.setClipboardCheckInterval($0) }
            )) {
                Text("100 ms").tag(0.1)
                Text("250 ms").tag(0.25)
                Text(L("Clipboard Check Interval Recommended")).tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
            }
            Text(L("Clipboard Check Interval Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

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

        DisclosureGroup(L("Clipboard Application Allow List Advanced")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    L("Enable Clipboard Application Allow List"),
                    isOn: Binding(
                        get: {
                            store.preferences.captureOnlyFromAllowedApplications
                        },
                        set: { store.setCaptureOnlyFromAllowedApplications($0) }
                    )
                )

                Button {
                    showingAllowedApplications = true
                } label: {
                    HStack {
                        Text(L("Manage Clipboard Allowed Applications"))
                        Spacer()
                        Text(store.preferences.allowedBundleIdentifiers.count.formatted())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Text(L("Clipboard Application Allow List Help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if store.preferences.captureOnlyFromAllowedApplications,
                   store.preferences.allowedBundleIdentifiers.isEmpty {
                    Label(
                        L("Clipboard Application Allow List Empty Warning"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
        .sheet(isPresented: $showingAllowedApplications) {
            ClipboardAllowedApplicationsSheet(store: store)
        }

        shortcutSettings

        ClipboardActionShortcutSettings(store: store)
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            shortcutStatus
        }
    }

    @ViewBuilder
    private var shortcutStatus: some View {
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
    }
}

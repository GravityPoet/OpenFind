import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var globalHotKey: GlobalHotKeyController
    @Bindable var driveAliveStore: DriveAliveStore
    @Bindable var driveAlive: DriveAliveController
    @Bindable var clipboardStore: ClipboardHistoryStore
    @Bindable var clipboard: ClipboardController
    @Bindable var keyboardLock: KeyboardLockController
    @Bindable var triggerStore: TriggerStore
    @Bindable var triggerCoordinator: TriggerCoordinator
    @Bindable var awakeHotKeys: AwakeHotKeyController
    @Bindable var awakeSessionPreferences: AwakeSessionPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var awakeNotifications: AwakeNotificationController
    @Bindable var awakeStatistics: AwakeStatisticsController
    @Bindable var sessionActivity: SessionActivityController
    @Bindable var powerProtect: PowerProtectController
    @Bindable var awakeSession: AwakeSessionController
    @State private var localUsageRecordCount = 0
    @AppStorage(SettingsPane.persistenceKey)
    private var selectedPaneValue = SettingsPane.search.rawValue
    @AppStorage(OpenFindInterfaceSize.persistenceKey)
    private var interfaceSizeValue = OpenFindInterfaceSize.standard.rawValue

    var body: some View {
        TabView(selection: selectedPane) {
            searchSettings
                .tabItem {
                    Label(L("Search"), systemImage: "magnifyingglass")
                }
                .tag(SettingsPane.search)

            awakeSettings
                .tabItem {
                    Label(L("Keep Awake"), systemImage: "moon.zzz")
                }
                .tag(SettingsPane.keepAwake)

            triggerSettings
                .tabItem {
                    Label(L("Triggers"), systemImage: "bolt")
                }
                .tag(SettingsPane.triggers)

            driveAliveSettings
                .tabItem {
                    Label(L("Drive Alive"), systemImage: "externaldrive")
                }
                .tag(SettingsPane.driveAlive)

            clipboardSettings
                .tabItem {
                    Label(L("Clipboard History"), systemImage: "doc.on.clipboard")
                }
                .tag(SettingsPane.clipboard)

            keyboardCleaningSettings
                .tabItem {
                    Label(L("Keyboard Cleaning"), systemImage: "keyboard")
                }
                .tag(SettingsPane.keyboardCleaning)
        }
        .frame(minWidth: 900, minHeight: 620)
        .openFindInterfaceSizing()
        .onAppear {
            localUsageRecordCount = SearchUsageStore.shared.recordCount
        }
        .onChange(of: viewModel.options) {
            Preferences.saveOptions(viewModel.options)
        }
    }

    private var searchSettings: some View {
        Form {
            Section {
                Picker(L("Interface Size"), selection: interfaceSize) {
                    ForEach(OpenFindInterfaceSize.allCases) { size in
                        Label(size.localizedName, systemImage: size.systemImage)
                            .tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Button(L("Show Welcome Guide")) {
                    AppDelegate.shared?.showWelcomeGuide(nil)
                }
            } header: {
                Text(L("Appearance"))
            } footer: {
                Text(L("Interface Size Help"))
            }

            Section(header: Text(L("Durable Defaults"))) {
                Picker(L("Default Target"), selection: $viewModel.options.target) {
                    Text(L("Name")).tag(SearchTarget.name)
                    Text(L("Contents")).tag(SearchTarget.content)
                    Text(L("Name or Contents")).tag(SearchTarget.both)
                }

                Picker(L("Default Match Mode"), selection: $viewModel.options.matchMode) {
                    Text(L("Contains")).tag(MatchMode.substring)
                    Text(L("Whole Word")).tag(MatchMode.wholeWord)
                    Text(L("Wildcard")).tag(MatchMode.wildcard)
                    Text(L("Regular Expression")).tag(MatchMode.regex)
                }

                Toggle(L("Case Sensitive"), isOn: $viewModel.options.caseSensitive)
                Toggle(L("Include Hidden Files"), isOn: $viewModel.options.includeHidden)
                Toggle(L("Search Inside Packages"), isOn: $viewModel.options.includePackages)
            }

            Section {
                Picker(L("Max Content File Size (MB)"), selection: sizeBinding) {
                    ForEach([1, 5, 16, 50, 100, 256, 512], id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                    Text(L("1 GB")).tag(1_024)
                    Text(L("No Limit")).tag(0)
                }
            } footer: {
                Text(L("Content Size Limit Help"))
            }

            Section {
                Picker(L("Content Acceleration Cache"), selection: contentIndexSizeBinding) {
                    ForEach([1, 2, 4, 8, 16], id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                    Text(L("No Limit")).tag(0)
                }
            } footer: {
                Text(L("Content Acceleration Cache Help"))
            }

            Section {
                Toggle(L("Use Local Open History"), isOn: $viewModel.options.useFrequencyRanking)

                Button(role: .destructive) {
                    SearchUsageStore.shared.clear()
                    localUsageRecordCount = 0
                } label: {
                    HStack {
                        Text(L("Clear Local Usage"))
                        Spacer()
                        Text(String(
                            format: L("Local Usage Count Format"),
                            Int64(localUsageRecordCount)
                        ))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(localUsageRecordCount == 0)
            } header: {
                Text(L("Local Ranking"))
            } footer: {
                Text(L("Local Ranking Help"))
            }

            Section(header: Text(L("Keyboard"))) {
                Toggle(L("Global Shortcut"), isOn: globalHotKeyBinding)

                LabeledContent(L("Toggle OpenFind")) {
                    HStack(spacing: 6) {
                        ShortcutRecorder(
                            shortcut: globalHotKey.shortcut,
                            prompt: L("Press Shortcut"),
                            accessibilityLabel: L("Toggle OpenFind")
                        ) { shortcut in
                            globalHotKey.setShortcut(shortcut)
                        }
                        .frame(width: 132)

                        if globalHotKey.shortcut != .defaultValue {
                            Button {
                                globalHotKey.resetShortcut()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Restore Default Shortcut"))
                            .accessibilityLabel(L("Restore Default Shortcut"))
                        }
                    }
                }

                switch globalHotKey.registrationState {
                case .disabled:
                    EmptyView()
                case .registered:
                    Label(L("Registered"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .conflict:
                    Label(L("Shortcut Conflicts"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .failed:
                    Label(L("Shortcut Unavailable"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text(L("Shortcut Recording Help"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(L("Clear Recent Searches"), role: .destructive) {
                    viewModel.clearRecentSearches()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var awakeSettings: some View {
        Form {
            AwakeSessionDefaultsSection(
                preferences: awakeSessionPreferences,
                closedDisplaySupported: awakeSession.closedDisplayModeSupported
            )
            AwakeAutomationSettingsSection(
                preferences: awakeSessionPreferences,
                launchAtLogin: launchAtLogin
            )
            AwakeNotificationSettingsSection(controller: awakeNotifications)
            AwakeStatisticsSettingsSection(controller: awakeStatistics)
            SessionActivitySettingsSection(
                preferences: awakeSessionPreferences,
                activity: sessionActivity
            )
            PowerProtectSettingsSection(controller: powerProtect)
            AwakeHotKeySettingsSection(controller: awakeHotKeys)
        }
        .formStyle(.grouped)
    }

    private var triggerSettings: some View {
        Form {
            TriggerSettingsSection(
                store: triggerStore,
                coordinator: triggerCoordinator,
                closedDisplaySupported: awakeSession.closedDisplayModeSupported
            )
        }
        .formStyle(.grouped)
    }

    private var driveAliveSettings: some View {
        Form {
            DriveAliveSettingsSection(store: driveAliveStore, controller: driveAlive)
        }
        .formStyle(.grouped)
    }

    private var clipboardSettings: some View {
        Form {
            ClipboardSettingsSection(store: clipboardStore, controller: clipboard)
        }
        .formStyle(.grouped)
    }

    private var keyboardCleaningSettings: some View {
        Form {
            KeyboardLockSettingsSection(controller: keyboardLock)
        }
        .formStyle(.grouped)
    }

    private var sizeBinding: Binding<Int> {
        Binding<Int>(
            get: { Int(viewModel.options.maxContentFileSize / (1024 * 1024)) },
            set: { viewModel.options.maxContentFileSize = Int64($0) * 1024 * 1024 }
        )
    }

    private var contentIndexSizeBinding: Binding<Int> {
        Binding<Int>(
            get: { Int(viewModel.options.maxContentIndexBytes / (1024 * 1024 * 1024)) },
            set: { viewModel.options.maxContentIndexBytes = Int64($0) * 1024 * 1024 * 1024 }
        )
    }

    private var globalHotKeyBinding: Binding<Bool> {
        Binding(
            get: { globalHotKey.isEnabled },
            set: { globalHotKey.setEnabled($0) }
        )
    }

    private var selectedPane: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane.resolve(selectedPaneValue) },
            set: { selectedPaneValue = $0.rawValue }
        )
    }

    private var interfaceSize: Binding<OpenFindInterfaceSize> {
        Binding(
            get: { OpenFindInterfaceSize.resolve(interfaceSizeValue) },
            set: { interfaceSizeValue = $0.rawValue }
        )
    }
}

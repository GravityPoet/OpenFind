import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SearchViewModel
    @Bindable var globalHotKey: GlobalHotKeyController
    @State private var localUsageRecordCount = 0

    var body: some View {
        Form {
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
                    Text("⌘⇧Space")
                        .font(.system(.body, design: .monospaced))
                }

                switch globalHotKey.registrationState {
                case .disabled:
                    EmptyView()
                case .registered:
                    Label(L("Registered"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Label(L("Shortcut Unavailable"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button(L("Clear Recent Searches"), role: .destructive) {
                    viewModel.clearRecentSearches()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 620)
        .navigationTitle(L("Settings"))
        .onAppear {
            localUsageRecordCount = SearchUsageStore.shared.recordCount
        }
        .onChange(of: viewModel.options) {
            Preferences.saveOptions(viewModel.options)
        }
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
}

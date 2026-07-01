import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SearchViewModel

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
                    ForEach([1, 5, 16, 50, 100], id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                }
            }

            Section {
                Button(L("Clear Recent Searches"), role: .destructive) {
                    viewModel.clearRecentSearches()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
        .navigationTitle(L("Settings"))
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
}

import SwiftUI

struct FilterBar: View {
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 16) {
                // Target Picker (Name / Contents / Both)
                Picker(L("Target"), selection: $viewModel.options.target) {
                    Text(L("Name")).tag(SearchTarget.name)
                    Text(L("Contents")).tag(SearchTarget.content)
                    Text(L("Name or Contents")).tag(SearchTarget.both)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .glassEffect(in: .rect(cornerRadius: 6))

                // Options Dropdown Menu
                Menu {
                    Picker(L("Default Match Mode"), selection: $viewModel.options.matchMode) {
                        Text(L("Contains")).tag(MatchMode.substring)
                        Text(L("Whole Word")).tag(MatchMode.wholeWord)
                        Text(L("Wildcard")).tag(MatchMode.wildcard)
                        Text(L("Regular Expression")).tag(MatchMode.regex)
                    }

                    Divider()

                    Toggle(L("Case Sensitive"), isOn: $viewModel.options.caseSensitive)
                    Toggle(L("Include Hidden Files"), isOn: $viewModel.options.includeHidden)
                    Toggle(L("Search Inside Packages"), isOn: $viewModel.options.includePackages)

                    Divider()

                    Toggle(L("Deep Index"), isOn: $viewModel.options.deepIndex)
                } label: {
                    Label(L("Options"), systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )

                Spacer()

                // Scope Management Menu
                Menu {
                    Button(action: {
                        viewModel.setScopes([URL(fileURLWithPath: "/System/Volumes/Data")])
                    }) {
                        Label(L("Search Whole Mac"), systemImage: "laptopcomputer")
                    }

                    Divider()

                    Button(action: {
                        let urls = FileActions.chooseDirectories()
                        for url in urls {
                            viewModel.addScope(url)
                        }
                    }) {
                        Label(L("Add Folder..."), systemImage: "plus")
                    }

                    if !viewModel.scopes.isEmpty {
                        Button(role: .destructive, action: {
                            viewModel.removeScopes(IndexSet(0..<viewModel.scopes.count))
                        }) {
                            Label(L("Clear Scopes"), systemImage: "trash")
                        }

                        Divider()

                        ForEach(Array(viewModel.scopes.enumerated()), id: \.element) { index, scope in
                            Button(action: {
                                viewModel.removeScopes(IndexSet(integer: index))
                            }) {
                                Label(scope.path == "/System/Volumes/Data" ? L("Whole Mac") : scope.path, systemImage: "folder.badge.minus")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(scopeButtonLabel)
                    }
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: viewModel.options) {
            viewModel.scheduleSearch()
        }
        .onChange(of: viewModel.scopes) {
            viewModel.scheduleSearch()
        }
    }

    private var scopeButtonLabel: String {
        if viewModel.scopes.isEmpty {
            return L("No Search Scopes")
        } else if viewModel.scopes.count == 1 {
            if viewModel.scopes[0].path == "/System/Volumes/Data" {
                return L("Whole Mac")
            }
            return viewModel.scopes[0].lastPathComponent
        } else {
            return String(format: L("%lld folders"), Int64(viewModel.scopes.count))
        }
    }
}

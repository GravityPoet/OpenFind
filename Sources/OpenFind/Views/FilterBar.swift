import SwiftUI

struct FilterBar: View {
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        OpenFindGlassContainer {
            HStack(spacing: 16) {
                // Target Picker (Name / Contents / Both)
                SearchTargetSelector(selection: $viewModel.options.target)
                    .frame(width: 320, height: 30)

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
                        .help(L("Deep Index Help"))
                } label: {
                    Label(L("Options"), systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .openFindGlassRoundedRectangle(cornerRadius: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )

                Spacer()

                // Scope Management Menu
                Menu {
                    if isWholeMacOnly {
                        Button(action: {}) {
                            Label(L("Whole Mac Enabled"), systemImage: "checkmark.circle")
                        }
                        .disabled(true)
                    } else {
                        Button(action: {
                            viewModel.setScopes([SearchScopes.wholeMacURL])
                        }) {
                            Label(L("Search Whole Mac"), systemImage: "laptopcomputer")
                        }
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

                    if !isWholeMacOnly {
                        Divider()

                        ForEach(Array(viewModel.scopes.enumerated()), id: \.element) { index, scope in
                            Button(action: {
                                viewModel.removeScopes(IndexSet(integer: index))
                            }) {
                                Label(scopeLabel(scope), systemImage: "folder.badge.minus")
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
                .openFindGlassRoundedRectangle(cornerRadius: 6)
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

    private var isWholeMacOnly: Bool {
        SearchScopes.isWholeMacOnly(viewModel.scopes)
    }

    private var scopeButtonLabel: String {
        if viewModel.scopes.isEmpty {
            return L("No Search Scopes")
        } else if viewModel.scopes.count == 1 {
            return scopeLabel(viewModel.scopes[0])
        } else {
            return String(format: L("%lld folders"), Int64(viewModel.scopes.count))
        }
    }

    private func scopeLabel(_ scope: URL) -> String {
        if SearchScopes.isWholeMac(scope) {
            return L("Whole Mac")
        }
        return scope.lastPathComponent.isEmpty ? scope.path(percentEncoded: false) : scope.lastPathComponent
    }
}

private struct SearchTargetSelector: View {
    @Binding var selection: SearchTarget
    @State private var hoveredTarget: SearchTarget?

    var body: some View {
        HStack(spacing: 0) {
            Text(L("Target"))
                .fontWeight(.semibold)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)

            divider

            ForEach(SearchTarget.allCases) { target in
                SearchTargetSegmentButton(
                    target: target,
                    selection: $selection,
                    hoveredTarget: $hoveredTarget
                )

                if target != .both {
                    divider
                }
            }
        }
        .openFindGlassRoundedRectangle(cornerRadius: 6)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onMoveCommand(perform: moveSelection)
        .animation(.easeOut(duration: 0.1), value: selection)
        .animation(.easeOut(duration: 0.1), value: hoveredTarget)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Target"))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1)
            .padding(.vertical, 5)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard let index = SearchTarget.allCases.firstIndex(of: selection) else { return }
        switch direction {
        case .left:
            selection = SearchTarget.allCases[max(0, index - 1)]
        case .right:
            selection = SearchTarget.allCases[min(SearchTarget.allCases.count - 1, index + 1)]
        default:
            break
        }
    }
}

private struct SearchTargetSegmentButton: View {
    let target: SearchTarget
    @Binding var selection: SearchTarget
    @Binding var hoveredTarget: SearchTarget?

    var body: some View {
        Button {
            selection = target
        } label: {
            Text(localizedLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fontWeight(isSelected ? .semibold : .regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .accessibilityLabel(Text(localizedLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering in
            hoveredTarget = isHovering ? target : nil
        }
    }

    private var isSelected: Bool {
        selection == target
    }

    private var localizedLabel: String {
        switch target {
        case .name: L("Name")
        case .content: L("Contents")
        case .both: L("Name or Contents")
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.11)
        }
        if hoveredTarget == target {
            return Color.primary.opacity(0.055)
        }
        return .clear
    }
}

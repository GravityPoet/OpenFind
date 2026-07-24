import SwiftUI

enum FilterBarLayoutMode: Equatable {
    case regular
    case compact

    static func resolve(
        availableWidth: CGFloat,
        interfaceSize: OpenFindInterfaceSize
    ) -> Self {
        let regularMinimum = 820 * max(1, interfaceSize.scale)
        return availableWidth >= regularMinimum ? .regular : .compact
    }
}

struct FilterBar: View {
    @Bindable var viewModel: SearchViewModel
    @Environment(\.openFindInterfaceSize) private var interfaceSize

    var body: some View {
        OpenFindGlassContainer {
            GeometryReader { proxy in
                let layout = FilterBarLayoutMode.resolve(
                    availableWidth: proxy.size.width,
                    interfaceSize: interfaceSize
                )
                toolbar(layout: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: interfaceSize.filterControlHeight)
        }
        .padding(.horizontal, interfaceSize.outerHorizontalPadding)
        .padding(.vertical, 8 * interfaceSize.scale)
        .onChange(of: viewModel.options) {
            viewModel.scheduleSearch()
        }
        .onChange(of: viewModel.scopes) {
            viewModel.scheduleSearch()
        }
    }

    @ViewBuilder
    private func toolbar(layout: FilterBarLayoutMode) -> some View {
        let isCompact = layout == .compact
        HStack(spacing: isCompact ? interfaceSize.compactSpacing : interfaceSize.regularSpacing) {
            SearchTargetSelector(
                selection: $viewModel.options.target,
                showsTitle: !isCompact,
                usesCompactLabels: isCompact
            )
            .frame(
                minWidth: isCompact ? 230 * interfaceSize.scale : nil,
                idealWidth: isCompact ? 275 * interfaceSize.scale : nil,
                maxWidth: isCompact ? 340 * interfaceSize.scale : nil,
                minHeight: interfaceSize.filterControlHeight,
                maxHeight: interfaceSize.filterControlHeight
            )
            .frame(width: isCompact ? nil : 320 * interfaceSize.scale)

            optionsMenu(compact: isCompact)

            Spacer(minLength: interfaceSize.compactSpacing)

            scopeMenu(compact: isCompact)
        }
    }

    private func optionsMenu(compact: Bool) -> some View {
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
            Group {
                if compact {
                    Image(systemName: "slider.horizontal.3")
                } else {
                    Label(L("Options"), systemImage: "slider.horizontal.3")
                }
            }
            .frame(
                minWidth: compact ? interfaceSize.filterControlHeight : nil,
                minHeight: interfaceSize.filterControlHeight
            )
            .padding(.horizontal, compact ? 0 : 10 * interfaceSize.scale)
        }
        .menuStyle(.borderlessButton)
        .openFindGlassRoundedRectangle(cornerRadius: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .help(L("Options"))
        .accessibilityLabel(L("Options"))
    }

    private func scopeMenu(compact: Bool) -> some View {
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
            Group {
                if compact {
                    Image(systemName: "folder")
                } else {
                    HStack(spacing: 4 * interfaceSize.scale) {
                        Image(systemName: "folder")
                        Text(scopeButtonLabel)
                    }
                }
            }
            .frame(
                minWidth: compact ? interfaceSize.filterControlHeight : nil,
                minHeight: interfaceSize.filterControlHeight
            )
            .padding(.horizontal, compact ? 0 : 10 * interfaceSize.scale)
        }
        .menuStyle(.borderlessButton)
        .openFindGlassRoundedRectangle(cornerRadius: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .help(scopeButtonLabel)
        .accessibilityLabel(scopeButtonLabel)
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
    let showsTitle: Bool
    let usesCompactLabels: Bool
    @State private var hoveredTarget: SearchTarget?

    var body: some View {
        HStack(spacing: 0) {
            if showsTitle {
                Text(L("Target"))
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)

                divider
            }

            ForEach(SearchTarget.allCases) { target in
                SearchTargetSegmentButton(
                    target: target,
                    selection: $selection,
                    hoveredTarget: $hoveredTarget,
                    usesCompactLabels: usesCompactLabels
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
    let usesCompactLabels: Bool

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
        case .both: usesCompactLabels ? L("Both") : L("Name or Contents")
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

import AppKit
import SwiftUI

struct SearchHeader: View {
    @Bindable var viewModel: SearchViewModel
    @FocusState.Binding var focusedTarget: SearchFocusTarget?
    let onMoveToResults: () -> Bool
    @State private var showRecentSearches = false
    @State private var showSearchHelp = false
    @Environment(\.openFindInterfaceSize) private var interfaceSize

    private var isFocused: Bool { focusedTarget == .query }

    var body: some View {
        OpenFindGlassContainer {
            HStack(spacing: 12 * interfaceSize.scale) {
                // Padding for traffic light window control buttons in hiddenTitleBar style
                Spacer()
                    .frame(width: 80 * interfaceSize.scale)

                Text(L("Full Search"))
                    .font(.system(size: 12 * interfaceSize.scale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                HStack(spacing: 8 * interfaceSize.scale) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(LD(viewModel.searchPlaceholderKey), text: $viewModel.options.query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("OpenFind.fullSearch.query")
                        .accessibilityLabel(L("Full Search"))
                        .focused($focusedTarget, equals: .query)
                        .onSubmit {
                            viewModel.startSearch()
                        }
                        .onChange(of: viewModel.options.query) {
                            viewModel.scheduleSearch()
                        }

                    if !viewModel.options.query.isEmpty {
                        Button {
                            viewModel.options.query = ""
                            viewModel.scheduleSearch(delay: .zero)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Clear Search"))
                        .accessibilityLabel(L("Clear Search"))
                    }

                    if !viewModel.recentSearches.isEmpty {
                        Button {
                            showRecentSearches.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 13, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("Recent Searches"))
                        .accessibilityLabel(L("Recent Searches"))
                        .accessibilityIdentifier("OpenFind.fullSearch.recent")
                        .popover(isPresented: $showRecentSearches, arrowEdge: .top) {
                            recentSearchesPopover
                        }
                    }

                    Button {
                        viewModel.options.caseSensitive.toggle()
                        viewModel.scheduleSearch(delay: .zero)
                    } label: {
                        Text("Aa")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(viewModel.options.caseSensitive ? Color.accentColor : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                viewModel.options.caseSensitive ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.options.caseSensitive ? L("Case Sensitive On") : L("Case Sensitive Off"))
                    .accessibilityLabel(viewModel.options.caseSensitive ? L("Case Sensitive On") : L("Case Sensitive Off"))
                    .accessibilityIdentifier("OpenFind.fullSearch.caseSensitive")

                    Button {
                        showSearchHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Search Syntax Help"))
                    .accessibilityLabel(L("Search Syntax Help"))
                    .accessibilityIdentifier("OpenFind.fullSearch.syntaxHelp")
                    .popover(isPresented: $showSearchHelp, arrowEdge: .top) {
                        searchSyntaxHelp
                    }

                    if viewModel.isSearching || viewModel.isSortingResults {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16 * interfaceSize.scale)
                .padding(.vertical, 8 * interfaceSize.scale)
                .openFindGlassCapsule()
                .overlay(
                    Capsule()
                        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isFocused ? 1.2 : 1)
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
        .padding(.horizontal, interfaceSize.outerHorizontalPadding)
        .padding(.top, 12 * interfaceSize.scale)
        .padding(.bottom, 8 * interfaceSize.scale)
        .background {
            SearchDownArrowMonitor(isActive: isFocused) {
                guard onMoveToResults() else { return false }
                focusedTarget = .results
                return true
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            focusedTarget = .query
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFindFocusSearch)) { _ in
            focusedTarget = nil
            Task { @MainActor in
                await Task.yield()
                focusedTarget = .query
            }
        }
    }

    private var recentSearchesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Recent Searches"), systemImage: "clock")
                .font(.headline)

            ForEach(viewModel.recentSearches, id: \.self) { search in
                Button {
                    showRecentSearches = false
                    viewModel.applyRecentSearch(search)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text(search)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button {
                showRecentSearches = false
                viewModel.clearRecentSearches()
            } label: {
                Label(L("Clear Recent Searches"), systemImage: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    private var searchSyntaxHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Search Syntax Help"), systemImage: "text.magnifyingglass")
                .font(.headline)
            Text(L("Search Syntax Help Detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach([
                "*.pdf briefing",
                "in:/Users/me ext:pdf",
                "content:\"Q4 budget\"",
                "size:>100MB dm:today",
                "report OR summary !draft"
            ], id: \.self) { example in
                Text(example)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }
}

private struct SearchDownArrowMonitor: NSViewRepresentable {
    let isActive: Bool
    let onDownArrow: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(hostView: view, isActive: isActive, onDownArrow: onDownArrow)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(hostView: nsView, isActive: isActive, onDownArrow: onDownArrow)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var hostView: NSView?
        private var isActive = false
        private var onDownArrow: () -> Bool = { false }
        private var monitor: Any?

        func update(hostView: NSView, isActive: Bool, onDownArrow: @escaping () -> Bool) {
            self.hostView = hostView
            self.isActive = isActive
            self.onDownArrow = onDownArrow
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive,
                      self.hostView?.window === NSApp.keyWindow,
                      event.keyCode == 125,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                if let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView,
                   fieldEditor.hasMarkedText() {
                    return event
                }
                return self.onDownArrow() ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

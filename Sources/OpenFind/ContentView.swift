import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: SearchViewModel

    @State private var selection = Set<SearchResult.ID>()
    @State private var sortOrder = [KeyPathComparator(\SearchResult.name)]

    /// 搜索中按插入序显示，避免频繁重排卡顿；搜索结束后才应用列排序。
    private var displayResults: [SearchResult] {
        viewModel.isSearching ? viewModel.results : viewModel.results.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            optionsBar
            scopeBar
            Divider()
            resultsArea
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索文件名或内容…", text: $viewModel.options.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit { viewModel.startSearch() }
                .onChange(of: viewModel.options.query) { viewModel.scheduleSearch() }
            if !viewModel.options.query.isEmpty {
                Button {
                    viewModel.options.query = ""
                    viewModel.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(viewModel.isSearching ? "停止" : "搜索") {
                viewModel.isSearching ? viewModel.cancel() : viewModel.startSearch()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.isSearching && !viewModel.canSearch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: 选项栏

    private var optionsBar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $viewModel.options.target) {
                ForEach(SearchTarget.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: viewModel.options.target) { viewModel.scheduleSearch() }

            Picker("方式", selection: $viewModel.options.matchMode) {
                ForEach(MatchMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .onChange(of: viewModel.options.matchMode) { viewModel.scheduleSearch() }

            Toggle("区分大小写", isOn: $viewModel.options.caseSensitive)
                .onChange(of: viewModel.options.caseSensitive) { viewModel.scheduleSearch() }
            Toggle("隐藏文件", isOn: $viewModel.options.includeHidden)
                .onChange(of: viewModel.options.includeHidden) { viewModel.scheduleSearch() }
            Toggle("搜索包内", isOn: $viewModel.options.includePackages)
                .onChange(of: viewModel.options.includePackages) { viewModel.scheduleSearch() }

            Spacer()
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: 范围栏

    private var scopeBar: some View {
        HStack(spacing: 8) {
            Text("范围").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(viewModel.scopes.enumerated()), id: \.element) { index, url in
                        scopeChip(url: url, index: index)
                    }
                }
            }
            Button {
                let picked = FileActions.chooseDirectories()
                picked.forEach(viewModel.addScope)
                if !picked.isEmpty { viewModel.scheduleSearch() }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("添加搜索文件夹")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func scopeChip(url: URL, index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").font(.caption2)
            Text(url.lastPathComponent).font(.caption).lineLimit(1)
            Button {
                viewModel.removeScopes(IndexSet(integer: index))
                viewModel.scheduleSearch()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(url.path(percentEncoded: false))
    }

    // MARK: 结果区

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.results.isEmpty {
            ContentUnavailableView {
                Label(viewModel.isSearching ? "搜索中…" : "无结果", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(viewModel.canSearch ? "尝试调整关键词或搜索范围。" : "输入关键词并选择至少一个文件夹。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ResultsView(results: displayResults, selection: $selection, sortOrder: $sortOrder)
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
                Text("搜索中…")
            }
            Text("\(viewModel.resultCount) 项结果")
                .foregroundStyle(.secondary)
            if viewModel.truncated {
                Text("（已达上限，结果被截断）").foregroundStyle(.orange)
            }
            Spacer()
            if viewModel.elapsed > 0 {
                Text(String(format: "用时 %.2f 秒", viewModel.elapsed))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

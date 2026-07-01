import AppKit

/// 对命中结果的系统级操作，集中一处便于复用。
enum FileActions {

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let text = urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 弹目录选择面板，允许多选。返回用户选中的目录，取消则空数组。
    @MainActor
    static func chooseDirectories() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "加入搜索范围"
        panel.message = "选择要搜索的文件夹"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

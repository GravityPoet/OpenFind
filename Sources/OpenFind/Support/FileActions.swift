import AppKit

/// System-level actions for search hits, consolidated for reuse.
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

    /// Show directory selection panel, allowing multiple selection.
    /// Returns selected URLs, or empty array if cancelled.
    @MainActor
    static func chooseDirectories() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add to Scope")
        panel.message = L("Select folders to search")
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func openSystemPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

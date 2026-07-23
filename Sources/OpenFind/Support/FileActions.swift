import AppKit

/// System-level actions for search hits, consolidated for reuse.
enum FileActions {

    static func open(_ url: URL) {
        if NSWorkspace.shared.open(url) {
            SearchUsageStore.shared.recordSuccessfulOpen(url)
        }
    }

    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        copyPathStrings(urls.map { $0.path(percentEncoded: false) })
    }

    static func copyFileNames(_ urls: [URL]) {
        copyStrings(urls.map(\.lastPathComponent))
    }

    static func copyFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    static func copyPathStrings(_ paths: [String]) {
        copyStrings(paths)
    }

    static func moveToTrash(_ urls: [URL], completion: @escaping @MainActor ([URL]) -> Void = { _ in }) {
        let existingURLs = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        guard !existingURLs.isEmpty else {
            Task { @MainActor in completion([]) }
            return
        }

        NSWorkspace.shared.recycle(existingURLs) { recycledURLs, error in
            let movedURLs = Array(recycledURLs.keys)
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    presentError(title: L("Move to Trash Failed"), message: message)
                }
                completion(movedURLs.isEmpty && message == nil ? existingURLs : movedURLs)
            }
        }
    }

    @MainActor
    static func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func copyStrings(_ strings: [String]) {
        let lines = strings.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n")
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

    @MainActor
    static func chooseFile(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openSystemPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openSettings(showSettings: () -> Void = {
        if let delegate = AppDelegate.shared {
            delegate.showSettingsWindow(nil)
        } else {
            NSApp.sendAction(#selector(AppDelegate.showSettingsWindow(_:)), to: nil, from: nil)
        }
    }) {
        NSApp.unhide(nil)
        showSettings()
        // MenuBarExtra dismisses its menu after this action returns. Activate on
        // the next main-loop turn so the Settings scene cannot remain behind the
        // application that was frontmost when the menu was opened.
        DispatchQueue.main.async {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

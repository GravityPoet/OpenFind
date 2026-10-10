import AppKit
import OpenFindBrowser
import SwiftUI

@MainActor
final class FileBrowserController: NSObject, NSWindowDelegate {
    static let shared = FileBrowserController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }
    func hide() { window?.orderOut(nil) }

    func show(location: URL? = nil, selected: [URL] = []) {
        BrowserSearchProvider.configure { request in
            try await BrowserSearchAdapter.search(request)
        }
        if let window {
            if let location { window.contentViewController = NSHostingController(rootView: BrowserRoot(location: location, selection: selected)) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            let host = NSHostingController(rootView: BrowserRoot(location: location, selection: selected))
            let window = NSWindow(contentViewController: host)
            window.title = "OpenFind · " + L("File Browser")
            window.identifier = NSUserInterfaceItemIdentifier("OpenFind.browser")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.minSize = NSSize(width: 850, height: 470)
            window.setContentSize(NSSize(width: 1050, height: 680))
            window.setFrameAutosaveName("OpenFind.browser")
            window.center(); window.isReleasedWhenClosed = false
            window.delegate = self; self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

import Foundation
@preconcurrency import QuickLookUI

@MainActor
final class QuickLookController: NSObject, @MainActor QLPreviewPanelDataSource,
    @MainActor QLPreviewPanelDelegate {
    private var items: [URL] = []
    private let clipboardMaterializer: ClipboardQuickLookMaterializer
    private var clipboardMaterialization: ClipboardQuickLookMaterialization?

    init(clipboardMaterializer: ClipboardQuickLookMaterializer = .init()) {
        self.clipboardMaterializer = clipboardMaterializer
        super.init()
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    func toggle(items: [URL]) {
        if isVisible {
            close()
            return
        }
        guard !items.isEmpty else { return }
        cleanupClipboardMaterialization()
        _ = show(items: items)
    }

    func toggle(entry: ClipboardEntry) throws {
        if isVisible {
            close()
            return
        }
        let materialization = try clipboardMaterializer.materialize(entry)
        cleanupClipboardMaterialization()
        clipboardMaterialization = materialization
        if !show(items: materialization.urls) {
            cleanupClipboardMaterialization()
        }
    }

    func update(items: [URL]) {
        guard isVisible else { return }
        guard !items.isEmpty else {
            close()
            return
        }
        cleanupClipboardMaterialization()
        self.items = items
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = min(panel.currentPreviewItemIndex, items.count - 1)
    }

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.close()
        }
        cleanupClipboardMaterialization()
    }

    func windowWillClose(_ notification: Notification) {
        cleanupClipboardMaterialization()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard items.indices.contains(index) else { return nil }
        return items[index] as NSURL
    }

    @discardableResult
    private func show(items: [URL]) -> Bool {
        self.items = items
        guard let panel = QLPreviewPanel.shared() else {
            self.items = []
            return false
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    private func cleanupClipboardMaterialization() {
        clipboardMaterializer.cleanup(clipboardMaterialization)
        clipboardMaterialization = nil
    }
}

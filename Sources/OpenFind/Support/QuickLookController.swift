import Foundation
@preconcurrency import QuickLookUI

@MainActor
final class QuickLookController: NSObject, @MainActor QLPreviewPanelDataSource {
    private var items: [URL] = []

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    func toggle(items: [URL]) {
        if isVisible {
            QLPreviewPanel.shared()?.close()
            return
        }
        guard !items.isEmpty else { return }
        show(items: items)
    }

    func update(items: [URL]) {
        guard isVisible else { return }
        guard !items.isEmpty else {
            QLPreviewPanel.shared()?.close()
            return
        }
        self.items = items
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = min(panel.currentPreviewItemIndex, items.count - 1)
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared()?.close()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard items.indices.contains(index) else { return nil }
        return items[index] as NSURL
    }

    private func show(items: [URL]) {
        self.items = items
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }
}

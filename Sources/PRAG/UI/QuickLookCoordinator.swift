import AppKit
import Quartz

/// Data source for the system QuickLook panel, driven from the shelf (Space / context menu).
@MainActor
final class QuickLookCoordinator: NSObject {
    private var urls: [URL] = []

    func toggle(urls: [URL], from window: NSWindow) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls
        window.makeKey()
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Space inside the preview closes it, like Finder.
        if event.type == .keyDown && event.keyCode == 49 { panel.orderOut(nil); return true }
        return false
    }
}

import SwiftUI
import AppKit
import NotchPipeCore

/// Transparent AppKit overlay on each tile/row that owns the pointer interaction:
/// Finder-style click selection, double-click to open, a native context menu, and
/// a multi-item NSDraggingSession (drag one selected tile → all selected files go).
struct DragOutView: NSViewRepresentable {
    let state: AppState
    let item: StashedItem
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragOutNSView {
        let v = DragOutNSView()
        v.configure(state: state, item: item, onHover: onHover)
        return v
    }

    func updateNSView(_ v: DragOutNSView, context: Context) {
        v.configure(state: state, item: item, onHover: onHover)
    }
}

final class DragOutNSView: NSView, NSDraggingSource {
    private weak var state: AppState?
    private var item: StashedItem?
    private var onHover: ((Bool) -> Void)?
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var draggedIDs: [UUID] = []

    func configure(state: AppState, item: StashedItem, onHover: @escaping (Bool) -> Void) {
        self.state = state
        self.item = item
        self.onHover = onHover
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Click selection

    override func mouseDown(with event: NSEvent) {
        guard let state, let item else { return }
        window?.makeKey()
        mouseDownEvent = event
        dragStarted = false
        let flags = event.modifierFlags
        if event.clickCount == 2 {
            NSWorkspace.shared.open(item.url)
            return
        }
        // Clicking an already-selected tile keeps the multi-selection so it can be dragged.
        if !flags.contains(.command) && !flags.contains(.shift) && state.selection.contains(item.id) { return }
        state.click(item.id, command: flags.contains(.command), shift: flags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        guard let state, let item, !dragStarted, event.clickCount == 1 else { return }
        let flags = event.modifierFlags
        // Plain click on part of a multi-selection collapses it to this one item.
        if !flags.contains(.command) && !flags.contains(.shift) && state.selection.count > 1 {
            state.selection = [item.id]
        }
    }

    // MARK: Drag out

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = mouseDownEvent, let state, let item else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        dragStarted = true

        let batch = state.selection.contains(item.id) ? state.items.filter { state.selection.contains($0.id) } : [item]
        draggedIDs = batch.map(\.id)
        let origin = convert(down.locationInWindow, from: nil)
        let dragItems: [NSDraggingItem] = batch.enumerated().map { idx, it in
            let di = NSDraggingItem(pasteboardWriter: it.url as NSURL)
            let image = ThumbnailCache.shared.cached(it.url) ?? NSWorkspace.shared.icon(forFile: it.url.path)
            let side: CGFloat = 54
            let offset = CGFloat(min(idx, 4)) * 5
            di.setDraggingFrame(NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset,
                                       width: side, height: side), contents: image)
            return di
        }
        let session = beginDraggingSession(with: dragItems, event: down, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        guard let state, operation != [] else { return }
        if state.settings.removeAfterDragOut {
            state.remove(Set(draggedIDs))
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let state, let item else { return nil }
        if !state.selection.contains(item.id) { state.selection = [item.id] }
        let urls = state.selectedItems.map(\.url)
        let menu = NSMenu()
        menu.addItem(MenuAction("Quick Look", "eye") { [weak self] in
            guard let window = self?.window else { return }
            state.quickLook?.toggle(urls: urls, from: window)
        })
        menu.addItem(MenuAction("Open", "arrow.up.forward.app") { urls.forEach { NSWorkspace.shared.open($0) } })
        menu.addItem(MenuAction("Reveal in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
        menu.addItem(MenuAction("Copy", "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        })
        if item.kind == .folder || item.kind == .code || item.kind == .text {
            menu.addItem(.separator())
            for (name, bundle) in [("Cursor", "com.todesktop.230313mzl4w4u92"), ("VS Code", "com.microsoft.VSCode")] {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    menu.addItem(MenuAction("Open in \(name)", "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    })
                }
            }
            menu.addItem(MenuAction("Open in Terminal", "terminal") {
                let dirs = urls.map { u -> URL in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                    return isDir.boolValue ? u : u.deletingLastPathComponent()
                }
                if let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open(dirs, withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
                }
            })
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("Remove from Shelf", "minus.circle") { state.removeSelected() })
        return menu
    }
}

/// NSMenuItem with a closure.
private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

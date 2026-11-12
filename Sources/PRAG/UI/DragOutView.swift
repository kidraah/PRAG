import SwiftUI
import AppKit
import PRAGCore

/// Transparent AppKit overlay on each tile/row that owns the pointer interaction:
/// Finder-style click selection, double-click to open, a native context menu, and
/// a multi-item NSDraggingSession (drag one selected tile → all selected files go).
struct DragOutView: NSViewRepresentable {
    /// Where the tile's own SwiftUI controls sit; clicks there must reach them, not the drag layer.
    enum ControlLayout { case tileCorners, rowEnds }

    let state: AppState
    let item: StashedItem
    var controls: ControlLayout = .tileCorners
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragOutNSView {
        let v = DragOutNSView()
        v.configure(state: state, item: item, controls: controls, onHover: onHover)
        return v
    }

    func updateNSView(_ v: DragOutNSView, context: Context) {
        v.configure(state: state, item: item, controls: controls, onHover: onHover)
    }
}

final class DragOutNSView: NSView, NSDraggingSource {
    private weak var state: AppState?
    private var item: StashedItem?
    private var onHover: ((Bool) -> Void)?
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var draggedIDs: [UUID] = []

    private var controls: DragOutView.ControlLayout = .tileCorners

    func configure(state: AppState, item: StashedItem, controls: DragOutView.ControlLayout,
                   onHover: @escaping (Bool) -> Void) {
        self.state = state
        self.item = item
        self.controls = controls
        self.onHover = onHover
    }

    /// Hit zones (in this view's coordinates) handed to the SwiftUI close / check buttons —
    /// only while those controls are on screen, so edge clicks still select/drag otherwise.
    /// Close shows on hover; the check shows on hover or whenever anything is selected.
    private var controlZones: [CGRect] {
        let b = bounds, z: CGFloat = 28
        let checkVisible = isHovering || !(state?.selection.isEmpty ?? true)
        var zones: [CGRect] = []
        switch controls {
        case .tileCorners:
            if isHovering { zones.append(CGRect(x: b.minX, y: b.maxY - z, width: z, height: z)) }
            if checkVisible { zones.append(CGRect(x: b.maxX - z, y: b.maxY - z, width: z, height: z)) }
        case .rowEnds:
            if checkVisible { zones.append(CGRect(x: b.minX, y: b.minY, width: 30, height: b.height)) }
            if isHovering { zones.append(CGRect(x: b.maxX - 30, y: b.minY, width: 30, height: b.height)) }
        }
        return zones
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if controlZones.contains(where: { $0.contains(local) }) { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var isHovering = false

    override func mouseEntered(with event: NSEvent) { isHovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { isHovering = false; onHover?(false) }
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
        // Inside PRAG a tile can be moved onto a tab; outside it's a copy.
        context == .outsideApplication ? [.copy, .link, .generic] : [.move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        guard let state, operation != [] else { return }
        if state.internalMoveHappened {      // moved onto one of our tabs, not dragged out
            state.internalMoveHappened = false
            return
        }
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
        let ids = state.selection
        let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let moveMenu = NSMenu()
        if item.groupID != nil {
            moveMenu.addItem(MenuAction("Recent", "clock") { state.move(ids, to: nil) })
        }
        for group in state.groups where group.id != item.groupID {
            moveMenu.addItem(MenuAction(group.name, "folder") { state.move(ids, to: group.id) })
        }
        if moveMenu.items.count > 0 { moveMenu.addItem(.separator()) }
        moveMenu.addItem(MenuAction("New Tab…", "folder.badge.plus") {
            let g = state.createGroup(moving: ids)
            state.activeTab = .group(g.id)
        })
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)
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

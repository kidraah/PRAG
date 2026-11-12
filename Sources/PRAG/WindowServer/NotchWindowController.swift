import AppKit
import SwiftUI
import Observation

/// Per-screen render model. `mode` lags `AppState.mode` so the window frame can shrink
/// only after the collapse animation finishes.
@MainActor
@Observable
final class ScreenShelfModel {
    var geometry: NotchGeometry
    var mode: ShelfMode = .collapsed
    var hasIndicator = false

    init(geometry: NotchGeometry) { self.geometry = geometry }
}

extension Animation {
    static let shelfExpand = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.1)
    static let shelfCollapse = Animation.spring(response: 0.36, dampingFraction: 1.0)   // critically damped: no bounce on close
    static let shelfPeek = Animation.spring(response: 0.3, dampingFraction: 0.62)
}

/// Owns one NotchPanel for one screen and keeps its frame in lock-step with the shelf state.
@MainActor
final class NotchWindowController {
    let panel: NotchPanel
    let model: ScreenShelfModel
    private let state: AppState
    private let hostView: NotchHostView
    private var generation = 0
    private var observing = true

    var displayID: CGDirectDisplayID { model.geometry.displayID }
    var geometry: NotchGeometry { model.geometry }

    init(geometry: NotchGeometry, state: AppState, quickLook: QuickLookCoordinator) {
        self.state = state
        self.model = ScreenShelfModel(geometry: geometry)
        model.hasIndicator = Self.wantsIndicator(state)
        let frame = geometry.collapsedFrame(hasIndicator: model.hasIndicator)
        panel = NotchPanel(contentRect: frame)
        hostView = NotchHostView(frame: CGRect(origin: .zero, size: frame.size))

        let root = NotchContainerView(state: state, model: model)
        let hosting = ShelfHostingView(rootView: root)
        hosting.sizingOptions = []
        hostView.install(hosting)
        panel.contentView = hostView
        panel.quickLook = quickLook

        hostView.state = state
        hostView.displayID = geometry.displayID
        panel.canBecomeKeyProvider = { [weak state, weak model] in
            guard let state, let model else { return false }
            return model.mode == .expanded && state.openScreenID == model.geometry.displayID
        }
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        observe()
    }

    func tearDown() {
        observing = false
        panel.orderOut(nil)
        panel.close()
    }

    func update(geometry: NotchGeometry) {
        guard geometry != model.geometry else { return }
        model.geometry = geometry
        hostView.displayID = geometry.displayID
        apply(animated: false)
    }

    /// True when the point is over the visible shelf body (used for hover/collapse decisions).
    func containsVisibleShelf(_ p: CGPoint) -> Bool {
        let size = geometry.shapeSize(for: model.mode, hasIndicator: model.hasIndicator,
                                      settings: state.page == .settings)
        return geometry.panelFrame(shapeSize: size, padded: false).insetBy(dx: -4, dy: -4).contains(p)
    }

    // MARK: State → window

    private static func wantsIndicator(_ state: AppState) -> Bool {
        state.settings.showIndicator && (!state.items.isEmpty || !state.jobs.isEmpty)
    }

    private func observe() {
        guard observing else { return }
        withObservationTracking {
            _ = state.mode
            _ = state.openScreenID
            _ = state.items.isEmpty
            _ = state.jobs.isEmpty
            _ = state.settings.showIndicator
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(animated: true)
                self.observe()
            }
        }
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        let target = state.mode(for: displayID)
        let indicator = Self.wantsIndicator(state)
        let geo = model.geometry

        // Collapsed = fully click-through: the notch/pill never intercepts a menu-bar click.
        // Hover and drags are detected by global monitors in AppDelegate instead.
        panel.ignoresMouseEvents = (target == .collapsed)

        if target != .collapsed {
            // Grow the window first (instantly, invisible), then animate the shape inside it.
            if panel.frame != geo.openFrame { panel.setFrame(geo.openFrame, display: true) }
            generation += 1
            let anim: Animation = target == .expanded ? .shelfExpand : .shelfPeek
            if model.mode != target || model.hasIndicator != indicator {
                withAnimation(animated ? anim : nil) {
                    model.mode = target
                    model.hasIndicator = indicator
                }
            }
            return
        }

        // Collapsing (or staying collapsed).
        if panel.isKeyWindow { relinquishKeyFocus() }
        let collapsedFrame = geo.collapsedFrame(hasIndicator: indicator)
        let needsAnimation = model.mode != .collapsed || model.hasIndicator != indicator
        guard needsAnimation else {
            if panel.frame != collapsedFrame { panel.setFrame(collapsedFrame, display: true) }
            return
        }
        // Growing wings while collapsed: make room first.
        if model.mode == .collapsed && indicator && !model.hasIndicator {
            panel.setFrame(collapsedFrame, display: true)
        }
        generation += 1
        let gen = generation
        let finish = { [weak self] in
            guard let self, gen == self.generation, self.state.mode(for: self.displayID) == .collapsed else { return }
            self.panel.setFrame(self.model.geometry.collapsedFrame(hasIndicator: self.model.hasIndicator), display: true)
        }
        if animated {
            withAnimation(.shelfCollapse, completionCriteria: .removed) {
                model.mode = .collapsed
                model.hasIndicator = indicator
            } completion: {
                finish()
            }
        } else {
            model.mode = .collapsed
            model.hasIndicator = indicator
            finish()
        }
    }

    /// Hand keyboard focus back to whatever app the user was in — we never activated,
    /// so the frontmost app is still theirs.
    private func relinquishKeyFocus() {
        panel.resignKey()
        NSWorkspace.shared.frontmostApplication?.activate()
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        // A focused text field (e.g. renaming a tab) owns every key.
        if panel.firstResponder is NSText { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, flags.contains(.command)) {
        case (49, false) where event.type == .keyDown:            // Space
            state.quickLook?.toggle(urls: state.selectedItems.map(\.url), from: panel)
            return true
        case (51, false), (117, false):                           // ⌫ / ⌦ — remove from shelf only
            guard event.type == .keyDown else { return false }
            state.removeSelected()
            return true
        case (53, _):                                             // Esc
            guard event.type == .keyDown else { return false }
            if state.isBuildingChain { state.isBuildingChain = false; state.chainDraft = [] }
            else if state.page == .settings { state.page = .shelf }
            else if !state.selection.isEmpty { state.selection = [] }
            else { state.collapse() }
            return true
        case (36, false):                                         // Return — open
            guard event.type == .keyDown else { return false }
            NSWorkspace.shared.open(state.selectedItems.map(\.url), withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: NSWorkspace.OpenConfiguration())
            return true
        case (_, true) where chars == "a":
            state.selectAll()
            return true
        case (_, true) where chars == "c":
            let urls = state.selectedItems.map { $0.url as NSURL }
            guard !urls.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls)
            state.showToast("Copied \(urls.count) file\(urls.count == 1 ? "" : "s")", symbol: "doc.on.doc")
            return true
        case (_, true) where chars == "v":
            state.ingest(pasteboard: .general)
            return true
        default:
            return false
        }
    }
}

/// SwiftUI host that acts on the very first click, even while the panel isn't key —
/// otherwise AppKit spends that click just focusing the window and controls feel laggy.
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container view: drop destination for the whole shelf + hover tracking.
final class NotchHostView: NSView {
    weak var state: AppState?
    var displayID: CGDirectDisplayID = 0
    private var hoverWork: DispatchWorkItem?

    private static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func install(_ hosting: NSView) {
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        guard let state else { return }
        state.isPointerInside = true
        state.cancelScheduledCollapse()
        guard state.mode(for: displayID) == .collapsed, state.settings.hoverToOpen, !state.isExternalDragActive else { return }
        hoverWork?.cancel()
        let id = displayID
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let state = self?.state, state.isPointerInside else { return }
                state.expand(on: id, reason: .hover)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        guard let state else { return }
        state.isPointerInside = false
        hoverWork?.cancel()
        guard state.mode(for: displayID) != .collapsed, !state.isExternalDragActive else { return }
        if state.reason == .hover || state.reason == .screenshot || state.reason?.isDragDriven == true {
            state.scheduleCollapse(after: 0.45)
        }
    }

    // MARK: Drop destination

    private func isOwnDrag(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView)?.window === window
    }

    /// The shelf tab under a drag location, using frames SwiftUI reported (top-left origin).
    private func tab(at location: NSPoint) -> ShelfTab? {
        guard let state, state.mode(for: displayID) == .expanded, state.page == .shelf else { return nil }
        let p = convert(location, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        return state.tabFrames.first { $0.value.insetBy(dx: -2, dy: -3).contains(flipped) }?.key
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let state else { return [] }
        let target = tab(at: sender.draggingLocation)
        if state.dropTargetTab != target { state.dropTargetTab = target }
        if isOwnDrag(sender) {
            // Tiles dragged within the shelf can only be dropped on a tab (to move them).
            return target == nil ? [] : .move
        }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let state else { return [] }
        if !isOwnDrag(sender) {
            state.isDropTargeted = true
            state.isPointerInside = true
            if state.mode(for: displayID) != .expanded {
                state.expand(on: displayID, reason: .drag)
                Haptics.align(state)
            }
        }
        return updateDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        state?.isDropTargeted = false
        state?.isPointerInside = false
        state?.dropTargetTab = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let state else { return false }
        let target = state.dropTargetTab ?? tab(at: sender.draggingLocation)
        state.isDropTargeted = false
        state.dropTargetTab = nil

        if isOwnDrag(sender) {
            guard let target else { return false }
            let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                        options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let paths = Set(urls.map(\.standardizedFileURL.path))
            let ids = Set(state.items.filter { paths.contains($0.url.standardizedFileURL.path) }.map(\.id))
            state.internalMoveHappened = true
            state.move(ids, to: target.groupID)
            Haptics.levelChange(state)
            return true
        }

        // Dropped onto a tab: open it so the new items land (and show) there.
        if let target { state.activeTab = target == .screenshots ? .recent : target }
        state.ingest(pasteboard: sender.draggingPasteboard)
        state.droppedOnShelf()
        Haptics.levelChange(state)
        return true
    }
}

@MainActor
enum Haptics {
    static func align(_ state: AppState) {
        guard state.settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func levelChange(_ state: AppState) {
        guard state.settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

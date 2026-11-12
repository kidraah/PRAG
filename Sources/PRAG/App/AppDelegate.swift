import AppKit
import Observation
import PRAGCore

/// Lifecycle + trigger coordinator: owns one shelf window per screen and routes the four
/// activation triggers (drag proximity, Shift-hold mid-drag, hotkey, shake) into AppState.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private let quickLook = QuickLookCoordinator()
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private let dragMonitor = DragMonitor()
    private let hotkeys = HotkeyManager()
    private var screenshotWatcher: ScreenshotWatcherService?
    private var statusItem: NSStatusItem?
    private var hapticFiredForDrag = false
    private var moveMonitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var hoverScreen: CGDirectDisplayID?
    /// How long the pointer must rest on the notch before hover opens the shelf.
    private static let hoverDwell: TimeInterval = 0.35

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.quickLook = quickLook
        state.pointerProbe = { [weak self] in self?.pointerIsOverOpenShelf() ?? false }
        state.keyFocusRequest = { [weak self] in
            guard let self, let id = self.state.openScreenID, let panel = self.controllers[id]?.panel else { return }
            panel.makeKey()
        }
        if AppEnv.isDemo {
            rebuildWindows()
            observeSettings()
            startDemo()
            return
        }
        state.restore()

        rebuildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        // Wake from sleep can reshuffle display IDs.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }

        wireDragMonitor()
        dragMonitor.start()
        startHoverMonitor()

        hotkeys.register(.commandShiftSpace) { [weak self] in self?.handleHotkey() }
        setupStatusItem()
        observeSettings()
        handleLaunchArguments()
    }

    private var demoDirector: DemoDirector?

    /// README recordings: scripted scene on a throwaway shelf (see DemoDirector).
    private func startDemo() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let scene = value("--demo"), let dir = value("--demo-files"),
              let notch = controllers.values.first(where: { $0.geometry.kind == .notch }) ?? controllers.values.first,
              let screen = NSScreen.screens.first(where: { $0.displayID == notch.displayID }) else {
            NSLog("PRAG demo: usage --demo <scene> --demo-files <dir> [--demo-log <file>] [--light]")
            return
        }
        let director = DemoDirector(state: state, controller: notch, screen: screen,
                                    files: URL(fileURLWithPath: dir),
                                    logURL: value("--demo-log").map { URL(fileURLWithPath: $0) })
        demoDirector = director
        Task { await director.run(scene: scene, light: args.contains("--light")) }
    }

    /// Dev/test hooks: `--stash <paths…>` adds files, `--open-shelf` expands on launch,
    /// `--settings` opens the settings page.
    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--new-tab"), args.indices.contains(i + 1) {
            let g = state.createGroup(named: args[i + 1])
            state.activeTab = .group(g.id)
        }
        if let i = args.firstIndex(of: "--stash") {
            let paths = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
            state.add(urls: paths.map { URL(fileURLWithPath: $0) })
        }
        if args.contains("--open-shelf") || args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    self?.showShelf()
                    self?.state.isPinned = true
                    if args.contains("--settings") { self?.state.page = .settings }
                }
            }
        }
        if let i = args.firstIndex(of: "--run"), args.indices.contains(i + 1),
           let preset = ActionPipeline.presets.first(where: { $0.id == args[i + 1] || $0.name == args[i + 1] }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let targets = self.state.visibleItems.filter { preset.isApplicable(kinds: [$0.kind], count: 1) }
                    self.state.run(preset, on: targets)
                }
            }
        }
        if args.contains("--cycle") {   // dev: open/close repeatedly to inspect the animation
            for k in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(k) * 1.6) { [weak self] in
                    MainActor.assumeIsolated { self?.showShelf() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8 + Double(k) * 1.6) { [weak self] in
                    MainActor.assumeIsolated { self?.state.collapse() }
                }
            }
        }
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                MainActor.assumeIsolated { self?.snapshotOpenShelf(to: path) }
            }
        }
    }

    /// Renders the open shelf's window contents to a PNG (no Screen Recording permission needed).
    private func snapshotOpenShelf(to path: String) {
        guard let id = state.openScreenID, let view = controllers[id]?.panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
        hotkeys.unregisterAll()
        screenshotWatcher?.stop()
    }

    // MARK: Screens

    private func rebuildWindows() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let geo = NotchGeometry.make(for: screen) else { continue }
            seen.insert(geo.displayID)
            if let existing = controllers[geo.displayID] {
                existing.update(geometry: geo)
            } else {
                controllers[geo.displayID] = NotchWindowController(geometry: geo, state: state, quickLook: quickLook)
            }
        }
        applyAppearance()
        for (id, controller) in controllers where !seen.contains(id) {
            controller.tearDown()
            controllers[id] = nil
            if state.openScreenID == id { state.collapse() }
        }
    }

    /// The shelf on the screen under the pointer (falls back to the main/notched screen).
    private func controllerUnderPointer(_ p: CGPoint = NSEvent.mouseLocation) -> NotchWindowController? {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
           let id = screen.displayID, let c = controllers[id] {
            return c
        }
        return controllers.values.first { $0.geometry.kind == .notch } ?? controllers.values.first
    }

    private func pointerIsOverOpenShelf() -> Bool {
        guard let id = state.openScreenID, let c = controllers[id] else { return false }
        return c.containsVisibleShelf(NSEvent.mouseLocation)
    }

    // MARK: Triggers

    private func wireDragMonitor() {
        dragMonitor.onDragBegan = { [weak self] in
            guard let self else { return }
            state.isExternalDragActive = true
            hapticFiredForDrag = false
        }

        // Trigger 1: drag proximity → peek glow, then expand within 60 pt.
        dragMonitor.onDragMoved = { [weak self] p in
            guard let self, let c = controllerUnderPointer(p) else { return }
            let d = c.geometry.distanceToTrigger(p)
            let id = c.displayID
            // With proximity off, only a drag that reaches the notch itself opens it.
            guard state.settings.dragProximity || d == 0 else { return }
            if d <= NotchGeometry.triggerDistance {
                if state.mode(for: id) != .expanded {
                    state.expand(on: id, reason: .drag)
                }
                if !hapticFiredForDrag { hapticFiredForDrag = true; Haptics.align(state) }
            } else if d <= NotchGeometry.peekDistance {
                if state.mode(for: id) == .collapsed { state.peek(on: id) }
            } else if state.reason?.isDragDriven == true, state.openScreenID == id || state.openScreenID != nil {
                // Drifted away: close a shelf that the drag opened, unless the pointer is over it.
                let over = state.openScreenID.flatMap { controllers[$0] }?.panel.frame.insetBy(dx: -40, dy: -40).contains(p) ?? false
                if !over && !state.isDropTargeted {
                    if state.mode == .peek || state.reason == .drag { state.collapse() }
                }
            }
        }

        // Trigger 2: hold Shift mid-drag → open the shelf on the pointer's screen.
        dragMonitor.onShiftHold = { [weak self] p in
            guard let self, state.settings.shiftTap, let c = controllerUnderPointer(p) else { return }
            state.expand(on: c.displayID, reason: .shiftTap)
            Haptics.align(state)
        }

        // Trigger 4: shake the cursor while dragging.
        dragMonitor.onShake = { [weak self] p in
            guard let self, state.settings.shake, let c = controllerUnderPointer(p) else { return }
            state.expand(on: c.displayID, reason: .shake)
            Haptics.align(state)
        }

        dragMonitor.onDragEnded = { [weak self] _ in
            guard let self else { return }
            state.isExternalDragActive = false
            guard state.isOpen else { return }
            if state.mode == .peek {
                state.collapse()
            } else if state.reason?.isDragDriven == true {
                // Give a drop on the shelf a moment to land, then close if the pointer is elsewhere.
                state.scheduleCollapse(after: 0.35)
            }
        }

        // Click anywhere outside the open shelf closes it.
        dragMonitor.onGlobalMouseDown = { [weak self] p in
            guard let self, state.isOpen, !state.isPinned else { return }
            if let id = state.openScreenID, let c = controllers[id], c.containsVisibleShelf(p) { return }
            state.collapse()
        }
    }

    /// Hover-to-open while collapsed. The collapsed panel ignores the mouse, so we watch pointer
    /// movement instead (only fires while the mouse actually moves → no idle cost).
    private func startHoverMonitor() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        moveMonitors = [global, local].compactMap { $0 }
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        if state.isOpen {
            cancelHover()
            // Hover-opened shelves close shortly after the pointer leaves the visible body.
            guard !state.isExternalDragActive, !state.isPinned, let reason = state.reason,
                  reason == .hover || reason == .screenshot || reason.isDragDriven else { return }
            if pointerIsOverOpenShelf() {
                state.cancelScheduledCollapse()
            } else if !state.isCollapseScheduled {
                state.scheduleCollapse(after: 0.22)
            }
            return
        }
        guard state.settings.hoverToOpen, !state.isExternalDragActive else {
            cancelHover()
            return
        }
        guard let c = controllers.values.first(where: { $0.geometry.triggerRect.insetBy(dx: -1, dy: -1).contains(p) }) else {
            cancelHover()
            return
        }
        guard hoverScreen != c.displayID else { return }
        hoverScreen = c.displayID
        let id = c.displayID
        // Intent dwell: the pointer has to rest on the notch for a moment. Passing over it on the
        // way to the menu bar leaves the rect before this fires, so nothing opens.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let c = self.controllers[id],
                      c.geometry.triggerRect.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation),
                      !self.state.isOpen else { return }
                self.state.isPointerInside = true
                self.state.expand(on: id, reason: .hover)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell, execute: work)
    }

    private func cancelHover() {
        hoverWork?.cancel()
        hoverWork = nil
        hoverScreen = nil
    }

    // Trigger 3: ⌘⇧Space. In Finder with a selection → stash it; otherwise toggle the shelf.
    private func handleHotkey() {
        guard let c = controllerUnderPointer() else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            let urls = FinderSelection.selectedURLs()
            if !urls.isEmpty {
                let added = state.add(urls: urls)
                state.expand(on: c.displayID, reason: .hotkey)
                state.showToast("Stashed \(added.count) from Finder", symbol: "tray.and.arrow.down.fill")
                return
            }
        }
        state.toggle(on: c.displayID, reason: .hotkey)
    }

    // MARK: Settings → services

    private func observeSettings() {
        withObservationTracking {
            _ = state.settings.shiftTap
            _ = state.settings.shake
            _ = state.settings.autoCatchScreenshots
            _ = state.settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSettings() }
        }
        dragMonitor.shiftEnabled = state.settings.shiftTap
        dragMonitor.shakeEnabled = state.settings.shake
        applyScreenshotWatcher()
        applyAppearance()
    }

    /// Auto = nil appearance, so panels follow the system light/dark switch live.
    private func applyAppearance() {
        let appearance = state.settings.appearance.nsAppearance
        for c in controllers.values { c.panel.appearance = appearance }
    }

    private func applyScreenshotWatcher() {
        if state.settings.autoCatchScreenshots {
            ScreenshotPrefs.disableFloatingThumbnail()
            guard screenshotWatcher == nil else { return }
            let watcher = ScreenshotWatcherService { [weak self] url in
                Task { @MainActor [weak self] in self?.caughtScreenshot(url) }
            }
            watcher.start()
            screenshotWatcher = watcher
        } else {
            ScreenshotPrefs.restoreFloatingThumbnail()
            screenshotWatcher?.stop()
            screenshotWatcher = nil
        }
    }

    private func caughtScreenshot(_ url: URL) {
        let added = state.add(urls: [url], origin: .screenshot)
        guard !added.isEmpty else { return }
        let target = controllers.values.first { $0.geometry.kind == .notch } ?? controllerUnderPointer()
        guard let target, !state.isOpen else { return }
        state.expand(on: target.displayID, reason: .screenshot)
        state.scheduleCollapse(after: 2.6)
    }

    // MARK: Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "PRAG")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Shelf", action: #selector(showShelf), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PRAG", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        item.menu = menu
        statusItem = item
    }

    @objc private func showShelf() {
        guard let c = controllers.values.first(where: { $0.geometry.kind == .notch }) ?? controllerUnderPointer() else { return }
        state.expand(on: c.displayID, reason: .statusMenu)
    }

    @objc private func showSettings() {
        showShelf()
        state.page = .settings
    }

    @objc private func clearShelf() { state.clearAll() }
}

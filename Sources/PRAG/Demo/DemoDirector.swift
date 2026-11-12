import AppKit
import QuartzCore
import PRAGCore

/// Plays scripted README scenes against the real app state and logs "camera" keyframes
/// (centre + zoom over time, in display-local points) for the zoom/follow post-process.
///
///   PRAG --demo park|act|sort|theme|hero [--light] --demo-files <dir> --demo-log <file.json>
@MainActor
final class DemoDirector {
    private let state: AppState
    private let controller: NotchWindowController
    private let screen: NSScreen
    private let stage: DemoStage
    private let files: URL
    private let logURL: URL?
    private var start = CACurrentMediaTime()
    private var cameraLog: [[String: Double]] = []

    init(state: AppState, controller: NotchWindowController, screen: NSScreen, files: URL, logURL: URL?) {
        self.state = state
        self.controller = controller
        self.screen = screen
        self.files = files
        self.logURL = logURL
        // A wallpaper.jpg next to the samples wins; otherwise use macOS's own Sonoma wallpaper.
        let custom = files.appendingPathComponent("wallpaper.jpg")
        let wallpaper = FileManager.default.fileExists(atPath: custom.path)
            ? custom : URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
        self.stage = DemoStage(screen: screen, wallpaper: wallpaper, panelLevel: controller.panel.level)
    }

    // MARK: Primitives

    private var now: Double { CACurrentMediaTime() - start }
    private var displayID: CGDirectDisplayID { controller.displayID }
    private var notchCenter: CGPoint { CGPoint(x: screen.frame.width / 2, y: 16) }

    private func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    private func file(_ name: String) -> URL { files.appendingPathComponent(name) }

    private func item(named name: String) -> StashedItem? { state.items.first { $0.displayName == name } }

    /// Centre of a tagged control, in display-local top-left points.
    private func anchor(_ id: String) -> CGPoint? {
        guard let r = state.demoAnchors[id] else { return nil }
        let panel = controller.panel.frame
        return CGPoint(x: panel.minX + r.midX - screen.frame.minX,
                       y: screen.frame.maxY - (panel.maxY - r.midY))
    }

    /// Ease the virtual camera to `center` at `zoom` over `duration`, starting now.
    private func camera(_ center: CGPoint, zoom: Double, duration: Double) {
        cameraLog.append(["t": now, "x": center.x, "y": center.y, "z": zoom, "d": duration])
    }

    private func move(to p: CGPoint, _ duration: Double) async {
        stage.moveCursor(to: p, duration: duration)
        await sleep(duration)
    }

    private func move(toAnchor id: String, _ duration: Double, dx: CGFloat = 0, dy: CGFloat = 0) async {
        guard let p = anchor(id) else { NSLog("PRAG demo: missing anchor \(id)"); return }
        await move(to: CGPoint(x: p.x + dx, y: p.y + dy), duration)
    }

    private func click(_ action: () -> Void = {}) async {
        stage.press()
        await sleep(0.1)
        action()
        stage.release()
        await sleep(0.12)
    }

    private func stash(_ names: [String]) {
        state.add(urls: names.map(file))
    }

    private func openShelf() {
        state.expand(on: displayID, reason: .statusMenu)
        state.isPinned = true
    }

    private func waitForJobs(timeout: Double = 12) async {
        let deadline = now + timeout
        while !state.jobs.isEmpty && now < deadline { await sleep(0.1) }
    }

    // MARK: Run

    func run(scene: String, light: Bool) async {
        state.settings.appearance = light ? .light : .dark
        state.settings.autoCatchScreenshots = false
        state.settings.showIndicator = true
        await prepare(scene)
        await sleep(1.2)                       // thumbnails load, layout settles

        // Sync marker: one magenta flash the post-process aligns t = 0 to.
        stage.model.syncFlash = true
        await sleep(0.12)
        stage.model.syncFlash = false
        start = CACurrentMediaTime()

        switch scene {
        case "park": await park()
        case "act": await act()
        case "sort": await sort()
        case "theme": await theme()
        case "hero": await hero()
        default: NSLog("PRAG demo: unknown scene \(scene)")
        }
        cameraLog.append(["t": now, "end": 1])
        writeLog()
        if scene != "hero" {
            await sleep(0.3)
            NSApp.terminate(nil)
        }
    }

    private func prepare(_ scene: String) async {
        switch scene {
        case "park":
            let x = screen.frame.width - 150
            stage.model.icons = ["Sunset Ridge.jpg", "Brand Mockup.png", "IMG_4821.HEIC"].enumerated().map { i, n in
                DemoStageModel.DesktopIcon(url: file(n), position: CGPoint(x: x, y: 170 + CGFloat(i) * 128))
            }
        case "act", "theme":
            stash(["Sunset Ridge.jpg", "Brand Mockup.png", "IMG_4821.HEIC"])
            openShelf()
        case "sort":
            stash(["Sunset Ridge.jpg", "Brand Mockup.png", "IMG_4821.HEIC", "Pitch Deck.pdf", "Contract Draft.pdf"])
            openShelf()
        case "hero":
            stash(["Sunset Ridge.jpg", "Brand Mockup.png", "IMG_4821.HEIC", "Pitch Deck.pdf"])
            openShelf()
        default: break
        }
    }

    // MARK: Scenes

    /// Park: drag three files from the desktop into the notch.
    private func park() async {
        let w = screen.frame.width
        camera(CGPoint(x: w * 0.6, y: 330), zoom: 1.0, duration: 0)
        stage.showCursor(at: CGPoint(x: w * 0.62, y: 640))
        await sleep(0.5)

        // Select the three icons.
        for i in stage.model.icons.indices {
            await move(to: stage.model.icons[i].position, i == 0 ? 0.75 : 0.32)
            await click { self.stage.model.icons[i].selected = true }
        }
        camera(CGPoint(x: w * 0.62, y: 300), zoom: 1.18, duration: 0.9)

        // Pick them up.
        await move(to: stage.model.icons[1].position, 0.3)
        stage.press()
        stage.beginDragGhost(stage.model.icons.map(\.url))
        for i in stage.model.icons.indices { stage.model.icons[i].dimmed = true }
        await sleep(0.2)

        // Toward the notch: magnetic peek, then open.
        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 1.2)
        await move(to: CGPoint(x: notchCenter.x + 70, y: 185), 0.75)
        state.peek(on: displayID)
        await move(to: CGPoint(x: notchCenter.x + 14, y: 70), 0.5)
        state.expand(on: displayID, reason: .statusMenu)
        state.isPinned = true
        state.isDropTargeted = true
        await sleep(0.45)

        // Drop.
        stage.release()
        stage.endDragGhost()
        state.isDropTargeted = false
        stash(stage.model.icons.map { $0.url.lastPathComponent })
        for i in stage.model.icons.indices {
            stage.model.icons[i].dimmed = false
            stage.model.icons[i].selected = false
        }
        await sleep(1.5)

        // Walk away: the shelf tucks back into the notch, keeping a count beside the camera.
        await move(to: CGPoint(x: notchCenter.x + 120, y: 560), 0.6)
        state.isPinned = false
        state.collapse()
        camera(CGPoint(x: notchCenter.x, y: 30), zoom: 2.7, duration: 0.9)
        await sleep(2.0)
        camera(CGPoint(x: w * 0.55, y: 330), zoom: 1.0, duration: 0.9)
        await sleep(1.0)
    }

    /// Act: one click on Web Ready → three optimised copies with savings badges.
    private func act() async {
        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 0)
        stage.showCursor(at: CGPoint(x: notchCenter.x + 200, y: 560))
        await sleep(0.5)

        if let p = anchor(ActionPipeline.webReady.id) {
            camera(CGPoint(x: p.x + 80, y: p.y - 40), zoom: 2.0, duration: 0.9)
        }
        await move(toAnchor: ActionPipeline.webReady.id, 0.9)
        await sleep(0.2)
        await click { self.state.run(.webReady) }

        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.6, duration: 0.8)
        await move(to: CGPoint(x: notchCenter.x + 60, y: 330), 0.6)
        await waitForJobs()
        await sleep(0.6)

        // Inspect a savings badge.
        if let p = anchor("tile.Sunset Ridge.webp") {
            camera(CGPoint(x: p.x, y: p.y + 20), zoom: 2.7, duration: 0.9)
            await move(to: CGPoint(x: p.x + 10, y: p.y + 30), 0.8)
        }
        await sleep(2.0)
        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 0.9)
        await sleep(1.1)
    }

    /// Sort: select two PDFs → new tab, then drag an image onto it.
    private func sort() async {
        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 0)
        stage.showCursor(at: CGPoint(x: notchCenter.x + 220, y: 560))
        await sleep(0.5)

        camera(CGPoint(x: notchCenter.x + 60, y: 150), zoom: 1.75, duration: 0.9)
        await move(toAnchor: "tile.Pitch Deck.pdf", 0.85)
        await click { if let i = self.item(named: "Pitch Deck.pdf") { self.state.click(i.id, command: false, shift: false) } }
        await sleep(0.25)
        await move(toAnchor: "check.Contract Draft.pdf", 0.45)
        await click { if let i = self.item(named: "Contract Draft.pdf") { self.state.click(i.id, command: true, shift: false) } }
        await sleep(0.4)

        if let p = anchor("tab.new") { camera(CGPoint(x: p.x - 140, y: p.y + 30), zoom: 2.1, duration: 0.8) }
        await move(toAnchor: "tab.new", 0.7)
        await click {
            let g = self.state.createGroup(named: "Client Work", moving: self.state.selection)
            self.state.activeTab = .group(g.id)
        }
        await sleep(1.3)

        camera(CGPoint(x: notchCenter.x - 60, y: 110), zoom: 1.8, duration: 0.8)
        await move(toAnchor: "tab.recent", 0.7)
        await click { self.state.activeTab = .recent }
        await sleep(0.6)

        // Drag a tile onto the new tab.
        guard let target = state.groups.first(where: { $0.name == "Client Work" }),
              let mock = item(named: "Brand Mockup.png") else { return }
        await move(toAnchor: "tile.Brand Mockup.png", 0.6)
        stage.press()
        stage.beginDragGhost([mock.url])
        await sleep(0.15)
        await move(toAnchor: "tab.group.Client Work", 0.75, dy: 4)
        state.dropTargetTab = .group(target.id)
        await sleep(0.4)
        stage.release()
        stage.endDragGhost()
        state.dropTargetTab = nil
        state.move([mock.id], to: target.id)
        await sleep(0.9)
        await move(toAnchor: "tab.group.Client Work", 0.25)
        await click { self.state.activeTab = .group(target.id) }
        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 0.9)
        await sleep(1.8)
    }

    /// Theme: Settings → Light, back to a light shelf.
    private func theme() async {
        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 0)
        stage.showCursor(at: CGPoint(x: notchCenter.x + 220, y: 560))
        await sleep(0.5)

        if let p = anchor("gear") { camera(CGPoint(x: p.x - 160, y: p.y + 60), zoom: 1.9, duration: 0.8) }
        await move(toAnchor: "gear", 0.85)
        await click { self.state.page = .settings }
        await sleep(0.7)

        if let p = anchor("segment.Light") { camera(CGPoint(x: p.x - 60, y: p.y - 40), zoom: 1.9, duration: 0.7) }
        await move(toAnchor: "segment.Light", 0.7)
        await click { self.state.settings.appearance = .light }
        await sleep(1.1)
        await move(toAnchor: "segment.Dark", 0.45)
        await click { self.state.settings.appearance = .dark }
        await sleep(0.9)
        await move(toAnchor: "segment.Light", 0.4)
        await click { self.state.settings.appearance = .light }
        await sleep(0.6)

        camera(CGPoint(x: notchCenter.x, y: 228), zoom: 1.48, duration: 0.8)
        await move(toAnchor: "back", 0.7)
        await click { self.state.page = .shelf }
        await move(to: CGPoint(x: notchCenter.x + 200, y: 480), 0.7)
        await sleep(1.6)
    }

    /// Hero still: a populated shelf with two optimised outputs, no cursor. Stays up.
    private func hero() async {
        let targets = state.items.filter { ["Sunset Ridge.jpg", "Brand Mockup.png"].contains($0.displayName) }
        state.run(.webReady, on: targets)
        await waitForJobs()
        await sleep(0.4)
        state.selection = []
        state.toast = nil
    }

    private func writeLog() {
        guard let logURL else { return }
        let payload: [String: Any] = [
            "display": ["w": screen.frame.width, "h": screen.frame.height, "scale": screen.backingScaleFactor],
            "camera": cameraLog,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: logURL)
        }
    }
}

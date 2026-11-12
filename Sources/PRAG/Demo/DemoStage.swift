import AppKit
import SwiftUI
import Observation

/// Everything the README recordings show besides PRAG itself: a clean wallpaper with a fake
/// menu bar and desktop icons (so the user's real windows never appear on camera) and a
/// scripted cursor with click ripples and a Finder-style drag ghost.
@MainActor
@Observable
final class DemoStageModel {
    struct DesktopIcon: Identifiable {
        let id = UUID()
        let url: URL
        var position: CGPoint
        var selected = false
        var dimmed = false
    }

    struct Ripple: Identifiable {
        let id = UUID()
        let position: CGPoint
    }

    var wallpaper: NSImage?
    var cursor = CGPoint(x: 900, y: 700)
    var cursorVisible = false
    var pressed = false
    var ripples: [Ripple] = []
    var ghost: [URL] = []
    var ghostVisible = false
    var icons: [DesktopIcon] = []
    var syncFlash = false
    var menuBarHeight: CGFloat = 32
    var notchRange: ClosedRange<CGFloat> = 0...0
}

@MainActor
final class DemoStage {
    let model = DemoStageModel()
    private var backdrop: NSWindow?
    private var overlay: NSWindow?

    init(screen: NSScreen, wallpaper: URL?, panelLevel: NSWindow.Level) {
        model.wallpaper = wallpaper.flatMap { NSImage(contentsOf: $0) }
        model.menuBarHeight = max(screen.safeAreaInsets.top, 24)
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.notchRange = (l.maxX - screen.frame.minX)...(r.minX - screen.frame.minX)
        }
        backdrop = makeWindow(screen: screen, level: NSWindow.Level(rawValue: panelLevel.rawValue - 1),
                              root: AnyView(DemoBackdropView(model: model)), opaque: true)
        overlay = makeWindow(screen: screen, level: NSWindow.Level(rawValue: panelLevel.rawValue + 2),
                             root: AnyView(DemoCursorView(model: model)), opaque: false)
    }

    private func makeWindow(screen: NSScreen, level: NSWindow.Level, root: AnyView, opaque: Bool) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = level
        w.isOpaque = opaque
        w.backgroundColor = opaque ? .black : .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        return w
    }

    func tearDown() {
        backdrop?.orderOut(nil)
        overlay?.orderOut(nil)
    }

    // MARK: Cursor choreography

    func showCursor(at p: CGPoint) {
        model.cursor = p
        withAnimation(.easeOut(duration: 0.25)) { model.cursorVisible = true }
    }

    func moveCursor(to p: CGPoint, duration: Double) {
        withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: duration)) { model.cursor = p }
    }

    func press() {
        withAnimation(.easeOut(duration: 0.08)) { model.pressed = true }
        let ripple = DemoStageModel.Ripple(position: model.cursor)
        model.ripples.append(ripple)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.model.ripples.removeAll { $0.id == ripple.id } }
        }
    }

    func release() {
        withAnimation(.easeOut(duration: 0.12)) { model.pressed = false }
    }

    func beginDragGhost(_ urls: [URL]) {
        model.ghost = urls
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { model.ghostVisible = true }
    }

    func endDragGhost() {
        withAnimation(.easeIn(duration: 0.18)) { model.ghostVisible = false }
    }
}

// MARK: - Views

private struct DemoBackdropView: View {
    let model: DemoStageModel

    var body: some View {
        GeometryReader { _ in
        ZStack(alignment: .topLeading) {
            // Fill a fixed-size layer so the image's larger natural size can't grow the stack.
            Color.black
                .overlay {
                    if let wp = model.wallpaper {
                        Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
            FakeMenuBar(height: model.menuBarHeight, notch: model.notchRange)
            ForEach(model.icons) { icon in
                DesktopIconView(icon: icon)
                    .position(icon.position)
            }
            // One-frame sync marker for the recording pipeline.
            if model.syncFlash { Color(red: 1, green: 0, blue: 1) }
        }
        }
        .ignoresSafeArea()
    }
}

private struct FakeMenuBar: View {
    let height: CGFloat
    let notch: ClosedRange<CGFloat>

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) {
                    Text($0).font(.system(size: 13, weight: .medium))
                }
            }
            .padding(.leading, 18)
            Spacer()
            HStack(spacing: 17) {
                Image(systemName: "battery.75percent").font(.system(size: 14))
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                Image(systemName: "switch.2").font(.system(size: 13, weight: .semibold))
                Text("Thu Nov 12  9:41 AM").font(.system(size: 13, weight: .medium))
            }
            .padding(.trailing, 16)
        }
        .foregroundStyle(.white)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.22))
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
    }
}

private struct DesktopIconView: View {
    let icon: DemoStageModel.DesktopIcon

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(url: icon.url, side: 64, corner: 6)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 8).fill(icon.selected ? Color.black.opacity(0.28) : .clear))
            Text(icon.url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(icon.selected ? Color(red: 0.04, green: 0.43, blue: 0.95) : .clear))
                .shadow(color: .black.opacity(icon.selected ? 0 : 0.8), radius: 2, y: 1)
        }
        .frame(width: 120)
        .opacity(icon.dimmed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.15), value: icon.selected)
        .animation(.easeOut(duration: 0.2), value: icon.dimmed)
    }
}

private struct DemoCursorView: View {
    let model: DemoStageModel
    private let arrow = NSCursor.arrow

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.ripples) { r in
                RippleView().position(r.position)
            }
            if model.ghostVisible {
                DragGhost(urls: model.ghost)
                    .position(x: model.cursor.x + 34, y: model.cursor.y + 40)
                    .transition(.scale(scale: 0.4, anchor: .topLeading).combined(with: .opacity))
            }
            if model.cursorVisible {
                let size = arrow.image.size
                Image(nsImage: arrow.image)
                    .resizable()
                    .frame(width: size.width * 1.25, height: size.height * 1.25)
                    .scaleEffect(model.pressed ? 0.86 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .position(x: model.cursor.x - arrow.hotSpot.x * 1.25 + size.width * 0.625,
                              y: model.cursor.y - arrow.hotSpot.y * 1.25 + size.height * 0.625)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct RippleView: View {
    @State private var grow = false

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(grow ? 0 : 0.85), lineWidth: grow ? 1 : 3)
            .background(Circle().fill(Color.white.opacity(grow ? 0 : 0.25)))
            .frame(width: grow ? 58 : 10, height: grow ? 58 : 10)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { grow = true } }
    }
}

private struct DragGhost: View {
    let urls: [URL]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { idx, url in
                    ThumbnailView(url: url, side: 60, corner: 7)
                        .rotationEffect(.degrees(Double(idx - 1) * 7))
                        .offset(x: CGFloat(idx) * 5, y: CGFloat(idx) * -3)
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 3)
                }
            }
            .opacity(0.92)
            if urls.count > 1 {
                Text("\(urls.count)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(Color(red: 1, green: 0.23, blue: 0.19)))
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 80, height: 80)
    }
}

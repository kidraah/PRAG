import SwiftUI
import PRAGCore

/// Root morphing container. The window never animates — this view morphs the silhouette
/// between collapsed (hidden behind the camera housing), peek (magnetic swell) and expanded.
///
/// Smoothness rules:
///  - Content is laid out ONCE at its full open size and only masked by the animating shape,
///    so nothing re-flows frame-by-frame while the shelf grows or shrinks.
///  - Every background layer stays in the tree and crossfades (no views popping in/out).
struct NotchContainerView: View {
    let state: AppState
    let model: ScreenShelfModel
    @Environment(\.colorScheme) private var scheme

    private var geo: NotchGeometry { model.geometry }
    private var mode: ShelfMode { model.mode }
    private var open: Bool { mode == .expanded }
    private var onThisScreen: Bool { state.openScreenID == geo.displayID }
    private var showingSettings: Bool { state.page == .settings && onThisScreen }
    private var glowing: Bool { mode == .peek || (state.isDropTargeted && onThisScreen) }

    var body: some View {
        let size = geo.shapeSize(for: mode, hasIndicator: model.hasIndicator, settings: showingSettings)
        let openSize = geo.shapeSize(for: .expanded, hasIndicator: true, settings: showingSettings)
        let ear = geo.earRadius(for: mode, hasIndicator: model.hasIndicator)
        let shape = NotchShape(ear: ear, bottom: geo.bottomRadius(for: mode))

        ZStack(alignment: .top) {
            background(shape)
            ZStack(alignment: .top) {
                // Always mounted (no rebuild on open = instant), laid out once at full size
                // and masked by the shape, so nothing re-flows while it animates.
                ShelfContentView(state: state, geometry: geo, ear: geo.earRadius(for: .expanded, hasIndicator: true))
                    .frame(width: openSize.width, height: openSize.height, alignment: .top)
                    .opacity(open ? 1 : 0)
                    .scaleEffect(open ? 1 : 0.985, anchor: .top)
                    // In quickly behind the growing shape; out faster than it shrinks.
                    .animation(open ? .easeOut(duration: 0.16) : .easeIn(duration: 0.14), value: open)
                    .allowsHitTesting(open)
                    .environment(\.shelfVisible, open)
                if mode == .peek {
                    PeekView(geometry: geo)
                        .environment(\.colorScheme, .dark)
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                }
                CollapsedIndicatorView(state: state, geometry: geo, ear: ear)
                    .opacity(mode == .collapsed && model.hasIndicator ? 1 : 0)
                    .environment(\.colorScheme, .dark)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: ShelfSpace.name)
        .onPreferenceChange(DemoAnchorKey.self) { anchors in
            MainActor.assumeIsolated { state.demoAnchors.merge(anchors) { $1 } }
        }
        .animation(.shelfExpand, value: state.page)
    }

    // MARK: Background
    // Collapsed/peek: solid black so it melts into the camera housing in either theme.
    // Open (dark):  black at the bezel → HUD glass.  Open (light): frosted light glass.

    @ViewBuilder
    private func background(_ shape: NotchShape) -> some View {
        let dark = scheme == .dark
        ZStack {
            VisualEffectBlur(material: dark ? .hudWindow : .popover)
            if dark {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.2),
                                       .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color.white.opacity(0.45)
            }
            Color.black.opacity(open ? 0 : 1)
        }
        .clipShape(shape)
        .overlay {
            // Inner rim, faded out where the shape meets the bezel so the seam is invisible.
            shape.stroke(glowing ? Theme.accent.opacity(0.6) : (open ? Theme.rim : Color.white.opacity(0.10)), lineWidth: 2)
                .clipShape(shape)
                .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: .top, endPoint: .bottom))
                .opacity(mode == .collapsed && !model.hasIndicator ? 0 : 1)
        }
        .shadow(color: glowing ? Theme.accent.opacity(0.35) : .black.opacity(open ? (dark ? 0.45 : 0.18) : 0),
                radius: glowing ? 18 : 16, y: 6)
        .animation(.easeOut(duration: 0.2), value: glowing)
    }
}

private struct ShelfVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the shelf is collapsed — looping animations pause so idle CPU stays at 0.
    var shelfVisible: Bool {
        get { self[ShelfVisibleKey.self] }
        set { self[ShelfVisibleKey.self] = newValue }
    }
}

enum ShelfSpace {
    static let name = "shelf"
}

/// Shown while a drag approaches: a magnetic swell with a hint below the camera.
private struct PeekView: View {
    let geometry: NotchGeometry
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: geometry.kind == .notch ? geometry.notchSize.height - 2 : 0)
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .offset(y: pulse ? 1.5 : -1)
                Text("Drop to park")
                    .font(Theme.label(11, .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Collapsed "wings" beside the camera: a mini stack on the left, count/progress on the right.
private struct CollapsedIndicatorView: View {
    let state: AppState
    let geometry: NotchGeometry
    let ear: CGFloat

    var body: some View {
        if geometry.kind == .notch {
            HStack(spacing: 0) {
                MiniStack(items: Array(state.items.suffix(3)))
                    .frame(width: NotchGeometry.wingWidth)
                Spacer(minLength: 0)
                Group {
                    if let job = state.jobs.first {
                        ProgressRing(progress: job.progress, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    } else {
                        Text("\(state.items.count)")
                            .font(Theme.numeric(11.5, .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                }
                .frame(width: NotchGeometry.wingWidth)
            }
            .padding(.horizontal, ear)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.items.count)
        } else {
            // Slim pill: a soft sheen signals "something is on the shelf".
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, 18)
                .padding(.vertical, 2.5)
        }
    }
}

private struct MiniStack: View {
    let items: [StashedItem]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                ThumbnailView(url: item.url, side: 16, corner: 4)
                    .rotationEffect(.degrees(Double(idx - items.count + 1) * 9))
                    .offset(x: CGFloat(idx - items.count + 1) * 2.5)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fillPressed, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

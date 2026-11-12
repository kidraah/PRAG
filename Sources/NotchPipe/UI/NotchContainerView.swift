import SwiftUI
import NotchPipeCore

/// Root morphing container. The window never animates — this view morphs the silhouette
/// between collapsed (hidden behind the camera housing), peek (magnetic swell) and expanded.
struct NotchContainerView: View {
    let state: AppState
    let model: ScreenShelfModel

    private var geo: NotchGeometry { model.geometry }
    private var mode: ShelfMode { model.mode }
    private var glowing: Bool { mode == .peek || (state.isDropTargeted && state.openScreenID == geo.displayID) }

    var body: some View {
        let size = geo.screenShapeSize(for: mode, hasIndicator: model.hasIndicator)
        let ear = geo.earRadius(for: mode, hasIndicator: model.hasIndicator)
        let shape = NotchShape(anchor: geo.anchor, ear: ear, bottom: geo.bottomRadius(for: mode))

        ZStack(alignment: geo.anchor.alignment) {
            background(shape)
            content(ear: ear)
                .frame(width: size.width, height: size.height, alignment: geo.anchor.alignment)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: geo.anchor.alignment)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Background: black at the bezel → HUD glass, hairline inner rim, shape-true shadow

    @ViewBuilder
    private func background(_ shape: NotchShape) -> some View {
        let dir = geo.anchor.outward
        let open = mode == .expanded
        ZStack {
            if open {
                VisualEffectBlur(material: .hudWindow)
                    .transition(.opacity)
            }
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: open ? 0.22 : 1),
                    .init(color: .black.opacity(open ? 0.80 : 1), location: 1),
                ],
                startPoint: dir.start, endPoint: dir.end)
        }
        .clipShape(shape)
        .overlay {
            // Inner rim, faded out where the shape meets the bezel so the seam is invisible.
            shape.stroke(glowing ? Theme.accent.opacity(0.7) : Theme.rim, lineWidth: 2)
                .clipShape(shape)
                .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: dir.start, endPoint: dir.end))
                .opacity(mode == .collapsed && !model.hasIndicator ? 0 : 1)
        }
        .shadow(color: glowing ? Theme.accent.opacity(0.55) : .black.opacity(open ? 0.45 : 0),
                radius: glowing ? 18 : 16, y: geo.anchor == .top ? 6 : 0)
        .animation(.easeOut(duration: 0.2), value: glowing)
    }

    // MARK: Content per mode

    @ViewBuilder
    private func content(ear: CGFloat) -> some View {
        switch mode {
        case .expanded:
            ShelfContentView(state: state, geometry: geo, ear: ear)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: geo.anchor == .top ? .top : .center))
                        .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.06)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
        case .peek:
            PeekView(geometry: geo)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
        case .collapsed:
            if model.hasIndicator {
                CollapsedIndicatorView(state: state, geometry: geo, ear: ear)
                    .transition(.opacity)
            }
        }
    }
}

/// Shown while a drag approaches: a magnetic swell with a hint below the camera.
private struct PeekView: View {
    let geometry: NotchGeometry
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            if geometry.anchor == .top { Spacer(minLength: geometry.kind == .notch ? geometry.notchSize.height - 2 : 0) }
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .offset(y: pulse ? 1.5 : -1)
                Text("Drop to stash")
                    .font(Theme.label(11, .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.bottom, geometry.anchor == .top ? 5 : 0)
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
                Spacer(minLength: geometry.notchSize.width)
                Group {
                    if let job = state.jobs.first {
                        ProgressRing(progress: job.progress, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    } else {
                        Text("\(state.items.count)")
                            .font(Theme.numeric(11.5, .semibold))
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                    }
                }
                .frame(width: NotchGeometry.wingWidth)
            }
            .padding(.horizontal, ear)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.items.count)
        } else {
            // Thin pill/tab: a soft mercury sheen signals "something is on the shelf".
            Capsule()
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.0), Theme.accent.opacity(0.75), Theme.accent.opacity(0.0)],
                                     startPoint: geometry.anchor.isVertical ? .top : .leading,
                                     endPoint: geometry.anchor.isVertical ? .bottom : .trailing))
                .padding(geometry.anchor.isVertical ? .vertical : .horizontal, 18)
                .padding(geometry.anchor.isVertical ? .horizontal : .vertical, 2.5)
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
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

import SwiftUI
import PRAGCore

/// Everything inside the expanded silhouette: header band beside the camera, the tab strip,
/// the tray, the action bar, and the toast.
struct ShelfContentView: View {
    let state: AppState
    let geometry: NotchGeometry
    let ear: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HeaderBand(state: state, geometry: geometry)
                .frame(height: geometry.topBandHeight)

            Group {
                switch state.page {
                case .shelf:
                    shelf
                case .settings:
                    SettingsPopoverView(state: state)
                        .padding(.top, 6)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, ear + 14)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            ToastView(toast: state.toast)
                .padding(.bottom, 50)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.page)
    }

    @ViewBuilder
    private var shelf: some View {
        let empty = state.visibleItems.isEmpty && state.jobs.isEmpty
        VStack(spacing: 8) {
            TabStripView(state: state)
                .frame(height: 24)
            StashTrayView(state: state)
                .frame(height: empty ? 160 : 118)
            if !state.visibleItems.isEmpty {
                ActionBarView(state: state)
                    .padding(.top, 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: empty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.activeTab)
    }
}

/// Header that lives in the strip beside the camera housing: identity on the left of the
/// notch, controls on the right. On the pill/edge it's a regular row.
private struct HeaderBand: View {
    let state: AppState
    let geometry: NotchGeometry

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: geometry.kind == .notch ? geometry.notchSize.width + 20 : 8)
            trailing
        }
        .padding(.top, geometry.kind == .notch ? 2 : 0)
    }

    private var leading: some View {
        HStack(spacing: 7) {
            if state.page == .settings {
                BandButton(symbol: "chevron.left", help: "Back to shelf") { state.page = .shelf }
                    .demoAnchor("back")
                Text("Settings").font(Theme.label(12, .semibold)).foregroundStyle(Theme.text)
            } else {
                Image(systemName: state.jobs.isEmpty ? "tray.full.fill" : "gearshape.2.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .symbolEffect(.pulse, isActive: !state.jobs.isEmpty)
                Text("PRAG").font(Theme.label(12, .bold)).tracking(0.4).foregroundStyle(Theme.text)
                if !state.items.isEmpty {
                    Text(countLabel)
                        .font(Theme.numeric(10.5))
                        .foregroundStyle(Theme.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var countLabel: String {
        let n = state.items.count
        if !state.selection.isEmpty { return "\(state.selection.count) of \(state.visibleItems.count) selected" }
        let bytes = state.items.reduce(Int64(0)) { $0 + $1.byteSize }
        return "\(n) · \(ByteDelta.format(bytes))"
    }

    private var trailing: some View {
        HStack(spacing: 2) {
            if state.page == .shelf {
                if !state.items.isEmpty {
                    BandButton(symbol: state.viewMode == .grid ? "list.bullet" : "square.grid.2x2",
                               help: state.viewMode == .grid ? "List view" : "Grid view") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            state.viewMode = state.viewMode == .grid ? .list : .grid
                        }
                    }
                    ClearAllButton {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.clearAll() }
                    }
                }
                BandButton(symbol: state.isPinned ? "pin.fill" : "pin", active: state.isPinned,
                           help: state.isPinned ? "Unpin" : "Keep open") { state.isPinned.toggle() }
                BandButton(symbol: "gearshape", help: "Settings") { state.page = .settings }
                    .demoAnchor("gear")
            } else {
                BandButton(symbol: "xmark", help: "Close") { state.collapse() }
            }
        }
        .fixedSize()
    }
}

private struct ToastView: View {
    let toast: Toast?

    var body: some View {
        ZStack {
            if let toast {
                HStack(spacing: 6) {
                    Image(systemName: toast.symbol)
                        .foregroundStyle(toast.isError ? Theme.danger : Theme.saving)
                    Text(toast.message)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(Theme.label(11, .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.chip))
                .overlay(Capsule().strokeBorder(Theme.rim, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: toast)
        .allowsHitTesting(false)
    }
}

/// Trash icon that morphs into a red "Clear All?" capsule; a second click confirms.
/// Reverts on its own after a few seconds or when the pointer leaves.
private struct ClearAllButton: View {
    let confirm: () -> Void
    @State private var armed = false
    @State private var hover = false
    @State private var revert: DispatchWorkItem?
    @Namespace private var ns

    var body: some View {
        Button {
            if armed {
                disarm()
                confirm()
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { armed = true }
                scheduleRevert(after: 3)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: armed ? "trash.fill" : "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if armed {
                    Text("Clear All?")
                        .font(Theme.label(11, .semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                }
            }
            .foregroundStyle(armed ? .white : (hover ? Theme.text : Theme.secondary))
            .padding(.horizontal, armed ? 9 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                Capsule()
                    .fill(armed ? Theme.danger : (hover ? Theme.fillHover : .clear))
                    .matchedGeometryEffect(id: "bg", in: ns)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in
            hover = h
            if !h && armed { scheduleRevert(after: 0.8) } else if h && armed { revert?.cancel() }
        }
        .help(armed ? "Click again to remove every item from the shelf (files on disk are kept)" : "Clear shelf")
        .animation(.easeOut(duration: 0.12), value: hover)
        .onDisappear { disarm() }
    }

    private func scheduleRevert(after seconds: Double) {
        revert?.cancel()
        let work = DispatchWorkItem { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { armed = false } }
        revert = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func disarm() {
        revert?.cancel()
        armed = false
    }
}

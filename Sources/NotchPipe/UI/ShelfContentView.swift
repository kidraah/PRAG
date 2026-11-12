import SwiftUI
import NotchPipeCore

/// Everything inside the expanded silhouette: header band beside the camera, the tray,
/// the action bar, and the toast. Lays itself out wide (notch/pill) or tall (edge dock).
struct ShelfContentView: View {
    let state: AppState
    let geometry: NotchGeometry
    let ear: CGFloat

    private var isTall: Bool { geometry.anchor.isVertical }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBand(state: state, geometry: geometry)
                .frame(height: isTall ? 30 : geometry.topBandHeight)

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
        .padding(.horizontal, isTall ? 14 : ear + 14)
        .padding(.top, isTall ? ear + 8 : 0)
        .padding(.bottom, isTall ? ear + 10 : 12)
        .overlay(alignment: .bottom) {
            ToastView(toast: state.toast)
                .padding(.bottom, isTall ? ear + 54 : 52)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.page)
    }

    @ViewBuilder
    private var shelf: some View {
        VStack(spacing: 10) {
            StashTrayView(state: state, vertical: isTall)
                .frame(height: isTall ? nil : 118)
                .frame(maxHeight: isTall ? .infinity : nil)
            if !state.items.isEmpty {
                ActionBarView(state: state, wraps: isTall)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.top, isTall ? 4 : 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.items.isEmpty)
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
                Text("Settings").font(Theme.label(12, .semibold)).foregroundStyle(Theme.text)
            } else {
                Image(systemName: state.jobs.isEmpty ? "tray.full.fill" : "gearshape.2.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom))
                    .symbolEffect(.pulse, isActive: !state.jobs.isEmpty)
                Text("Shelf").font(Theme.label(12, .semibold)).foregroundStyle(Theme.text)
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
        if !state.selection.isEmpty { return "\(state.selection.count) of \(n)" }
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
                    BandButton(symbol: "trash", help: "Clear shelf (files on disk are untouched)") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.clearAll() }
                    }
                }
                BandButton(symbol: state.isPinned ? "pin.fill" : "pin", active: state.isPinned,
                           help: state.isPinned ? "Unpin" : "Keep open") { state.isPinned.toggle() }
                BandButton(symbol: "gearshape", help: "Settings") { state.page = .settings }
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
                .background(Capsule().fill(.black.opacity(0.88)))
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

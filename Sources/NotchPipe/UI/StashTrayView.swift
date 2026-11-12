import SwiftUI
import NotchPipeCore

/// The file tray: grid of tiles (row on the notch, column on an edge dock) or a compact list.
/// Each item hosts an AppKit drag source so multi-selection drags out as one gesture.
struct StashTrayView: View {
    let state: AppState
    let vertical: Bool

    var body: some View {
        if state.items.isEmpty && state.jobs.isEmpty {
            EmptyDropView(isTargeted: state.isDropTargeted)
        } else if state.viewMode == .list {
            listView
        } else {
            gridView
        }
    }

    // MARK: Grid

    private var gridView: some View {
        ScrollViewReader { proxy in
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                let layout = vertical
                    ? AnyLayout(GridFlowLayout(spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    ForEach(state.items) { item in
                        ItemTile(state: state, item: item)
                            .id(item.id)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    ForEach(state.jobs) { job in
                        JobTile(state: state, job: job)
                            .id(job.id)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.74), value: state.items.map(\.id))
            .animation(.spring(response: 0.38, dampingFraction: 0.74), value: state.jobs.map(\.id))
            .onChange(of: state.items.count) { old, new in
                guard new > old, let last = state.freshItemIDs.first else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { proxy.scrollTo(last) }
            }
        }
        .overlay { if state.isDropTargeted { DropHalo() } }
    }

    // MARK: List

    private var listView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(state.items) { item in
                    ItemRow(state: state, item: item)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(state.jobs) { job in
                    JobRow(state: state, job: job)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.items.map(\.id))
        }
        .overlay { if state.isDropTargeted { DropHalo() } }
    }
}

// MARK: - Tiles

private struct ItemTile: View {
    let state: AppState
    let item: StashedItem
    @State private var hover = false

    private var selected: Bool { state.selection.contains(item.id) }
    private var fresh: Bool { state.freshItemIDs.contains(item.id) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                ThumbnailView(url: item.url, side: 58, corner: 11)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                if let delta = item.delta {
                    DeltaBadge(delta: delta, compact: true)
                        .offset(y: 7)
                }
            }
            .frame(width: 66, height: 64)
            .overlay(alignment: .topTrailing) {
                if item.origin == .screenshot {
                    cornerGlyph("camera.viewfinder")
                } else if item.isProcessed {
                    cornerGlyph("sparkles")
                }
            }

            Text(item.displayName)
                .font(Theme.label(10, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, item.delta == nil ? 0 : 4)
            Text(item.delta.map(\.summary) ?? ByteDelta.format(item.byteSize))
                .font(Theme.numeric(8.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .frame(width: 86, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.20) : (hover ? Theme.fillHover : Theme.fill.opacity(0.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.85) : (fresh ? Theme.saving.opacity(0.8) : .clear), lineWidth: 1.2)
        )
        .shadow(color: fresh ? Theme.saving.opacity(0.45) : .clear, radius: 10)
        .overlay(DragOutView(state: state, item: item, onHover: { hover = $0 }))
        .animation(.easeOut(duration: 0.14), value: hover)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .animation(.easeOut(duration: 0.6), value: fresh)
        .help(helpText)
    }

    private var helpText: String {
        var s = item.url.path
        if !item.appliedSteps.isEmpty { s += "\n" + item.appliedSteps.map(\.title).joined(separator: " › ") }
        if let d = item.delta { s += "\n\(d.percentString) · \(d.summary)" }
        return s
    }

    private func cornerGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(Theme.accentDeep))
            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
            .offset(x: 3, y: -3)
    }
}

private struct JobTile: View {
    let state: AppState
    let job: PipelineJob
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                ProgressRing(progress: job.progress, lineWidth: 3.5)
                    .frame(width: 46, height: 46)
                if hover {
                    Button { state.cancel(job: job.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.fillHover))
                    }
                    .buttonStyle(PressableStyle())
                    .help("Cancel")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: job.pipeline.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse)
                }
            }
            .frame(width: 66, height: 64)
            Text(job.pipeline.name)
                .font(Theme.label(10, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(Int(job.progress * 100))%")
                .font(Theme.numeric(8.5)).foregroundStyle(Theme.tertiary)
                .contentTransition(.numericText())
        }
        .padding(6)
        .frame(width: 86, height: 112)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hover)
    }
}

// MARK: - List rows

private struct ItemRow: View {
    let state: AppState
    let item: StashedItem
    @State private var hover = false
    private var selected: Bool { state.selection.contains(item.id) }

    var body: some View {
        HStack(spacing: 9) {
            ThumbnailView(url: item.url, side: 24, corner: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(Theme.label(11, .medium)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if !item.appliedSteps.isEmpty {
                    Text(item.appliedSteps.map(\.title).joined(separator: " › "))
                        .font(Theme.label(9)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let d = item.delta {
                DeltaBadge(delta: d, compact: false)
            } else {
                Text(ByteDelta.format(item.byteSize)).font(Theme.numeric(10)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.22) : (hover ? Theme.fillHover : .clear)))
        .overlay(DragOutView(state: state, item: item, onHover: { hover = $0 }))
    }
}

private struct JobRow: View {
    let state: AppState
    let job: PipelineJob

    var body: some View {
        HStack(spacing: 9) {
            ProgressRing(progress: job.progress, lineWidth: 2.5).frame(width: 20, height: 20)
            Text(job.pipeline.breadcrumb).font(Theme.label(11, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Button { state.cancel(job: job.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

// MARK: - Badges & empty state

/// "-64% · 5.1 MB → 1.8 MB" — green when smaller, amber when larger.
struct DeltaBadge: View {
    let delta: ByteDelta
    var compact: Bool

    var body: some View {
        let tint = delta.isSaving ? Theme.saving : Theme.growth
        HStack(spacing: 3) {
            Image(systemName: delta.isSaving ? "arrow.down" : "arrow.up")
                .font(.system(size: compact ? 7 : 8, weight: .heavy))
            Text(delta.percentString)
            if !compact {
                Text("· " + delta.summary).foregroundStyle(tint.opacity(0.75))
            }
        }
        .font(Theme.numeric(compact ? 9 : 9.5, .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
        .fixedSize()
    }
}

private struct EmptyDropView: View {
    let isTargeted: Bool
    @State private var bob = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isTargeted ? Theme.accent : Theme.hairline.opacity(1.6),
                          style: StrokeStyle(lineWidth: 1.2, dash: [5, 5], dashPhase: bob ? 10 : 0))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isTargeted ? Theme.accent.opacity(0.10) : Color.white.opacity(0.025)))
            .overlay {
                VStack(spacing: 7) {
                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isTargeted ? Theme.accent : Theme.secondary)
                        .offset(y: bob ? 2 : -2)
                    Text(isTargeted ? "Release to stash" : "Drop files, links or text")
                        .font(Theme.label(12, .semibold))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        hint("⇧", "hold while dragging")
                        hint("⌘⇧␣", "toggle / stash Finder selection")
                    }
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bob = true }
            }
            .animation(.easeOut(duration: 0.18), value: isTargeted)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Theme.numeric(9.5, .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fillHover))
            Text(text).font(Theme.label(9.5)).foregroundStyle(Theme.tertiary)
        }
    }
}

private struct DropHalo: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.08)))
            .overlay(
                Label("Release to stash", systemImage: "tray.and.arrow.down.fill")
                    .font(Theme.label(11, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.85)))
            )
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// Wrapping grid used for the tall (edge-docked) shelf.
struct GridFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

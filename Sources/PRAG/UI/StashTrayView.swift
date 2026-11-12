import SwiftUI
import PRAGCore

/// The file tray: grid of tiles (row on the notch, column on an edge dock) or a compact list.
/// Each item hosts an AppKit drag source so multi-selection drags out as one gesture.
struct StashTrayView: View {
    let state: AppState

    private var emptyTitle: String {
        switch state.activeTab {
        case .recent: "Drop files, links or text"
        case .screenshots: state.settings.autoCatchScreenshots ? "New screenshots land here" : "Turn on Auto-Catch in Settings"
        case .group(let id): "Drop files to park them in \(state.groupName(id))"
        }
    }

    var body: some View {
        if state.visibleItems.isEmpty && state.jobs.isEmpty {
            EmptyDropView(title: emptyTitle, isTargeted: state.isDropTargeted)
        } else if state.viewMode == .list {
            listView
        } else {
            gridView
        }
    }

    // MARK: Grid

    private var gridView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.visibleItems) { item in
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
            .animation(.spring(response: 0.38, dampingFraction: 0.74), value: state.visibleItems.map(\.id))
            .animation(.spring(response: 0.38, dampingFraction: 0.74), value: state.jobs.map(\.id))
            .onChange(of: state.visibleItems.count) { old, new in
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
                ForEach(state.visibleItems) { item in
                    ItemRow(state: state, item: item)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(state.jobs) { job in
                    JobRow(state: state, job: job)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.visibleItems.map(\.id))
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
    /// Once anything is selected, every tile shows its check so multi-select is obvious.
    private var showsCheck: Bool { hover || selected || !state.selection.isEmpty }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                ThumbnailView(url: item.url, side: 58, corner: 11)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)
                    .demoAnchor("tile.\(item.displayName)")
                if let delta = item.delta {
                    DeltaBadge(delta: delta, compact: true)
                        .offset(y: 7)
                }
            }
            .frame(width: 66, height: 64)

            Text(item.displayName)
                .font(Theme.label(10, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, item.delta == nil ? 0 : 4)
            HStack(spacing: 3) {
                if let origin = originSymbol {
                    Image(systemName: origin).font(.system(size: 7.5, weight: .semibold))
                }
                Text(item.delta.map(\.summary) ?? ByteDelta.format(item.byteSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(Theme.numeric(8.5))
            .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .frame(width: 86, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.16) : (hover ? Theme.fill : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.9) : (fresh ? Theme.saving.opacity(0.7) : .clear), lineWidth: 1)
        )
        .overlay(DragOutView(state: state, item: item, controls: .tileCorners, onHover: { hover = $0 }))
        // Controls sit above the drag layer so they receive their own clicks.
        .overlay(alignment: .topLeading) {
            if hover {
                CloseDot { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.remove([item.id]) } }
                    .padding(1)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsCheck {
                CheckDot(isOn: selected) { state.click(item.id, command: true, shift: false) }
                    .demoAnchor("check.\(item.displayName)")
                    .padding(1)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: hover)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showsCheck)
        .animation(.easeOut(duration: 0.6), value: fresh)
        .help(helpText)
    }

    private var originSymbol: String? {
        switch item.origin {
        case .screenshot: "camera.viewfinder"
        case .processed: "sparkles"
        default: nil
        }
    }

    private var helpText: String {
        var s = item.url.path
        if !item.appliedSteps.isEmpty { s += "\n" + item.appliedSteps.map(\.title).joined(separator: " › ") }
        if let d = item.delta { s += "\n\(d.percentString) · \(d.summary)" }
        return s
    }
}

/// macOS window-style close button. The × is always drawn so it never flickers in and out.
private struct CloseDot: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                Circle().strokeBorder(.black.opacity(0.22), lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.62))
            }
            .frame(width: 15, height: 15)
            .scaleEffect(hover ? 1.12 : 1)
            .frame(width: 24, height: 24)        // generous hit target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hover)
        .help("Remove from shelf (the file on disk is kept)")
    }
}

/// Selection check: hollow ring when off, filled system-blue check when on.
private struct CheckDot: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isOn ? Theme.accent : Theme.chip.opacity(0.7))
                Circle().strokeBorder(isOn ? Theme.accent : Theme.secondary, lineWidth: 1.2)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 15, height: 15)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Deselect" : "Select (multi-select)")
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
            .strokeBorder(Theme.hairline, lineWidth: 0.75))
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
            if hover || selected || !state.selection.isEmpty {
                // Layout placeholder; the clickable check is overlaid above the drag layer.
                Color.clear.frame(width: 15, height: 15)
            }
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
        .overlay(DragOutView(state: state, item: item, controls: .rowEnds, onHover: { hover = $0 }))
        .overlay(alignment: .leading) {
            // Check sits above the drag layer; re-place it at the same spot.
            if hover || selected || !state.selection.isEmpty {
                CheckDot(isOn: selected) { state.click(item.id, command: true, shift: false) }
                    .padding(.leading, 4)
            }
        }
        .overlay(alignment: .trailing) {
            if hover {
                CloseDot { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.remove([item.id]) } }
                    .padding(.trailing, 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: hover)
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
        .background(Capsule().fill(Theme.chip))
        .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
        .fixedSize()
    }
}

private struct EmptyDropView: View {
    let title: String
    let isTargeted: Bool
    var body: some View {
        // Static on purpose: no looping animation, so an open, empty shelf costs no CPU.
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isTargeted ? Theme.accent : Theme.hairline.opacity(1.6),
                          style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isTargeted ? Theme.accent.opacity(0.10) : Theme.fill.opacity(0.5)))
            .overlay {
                VStack(spacing: 7) {
                    Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isTargeted ? Theme.accent : Theme.secondary)
                        .offset(y: isTargeted ? 2 : 0)
                        .contentTransition(.symbolEffect(.replace))
                    Text(isTargeted ? "Release to park" : title)
                        .font(Theme.label(12, .semibold))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        hint("⇧", "hold while dragging")
                        hint("⌘⇧␣", "toggle / stash Finder selection")
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
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
                Label("Release to park", systemImage: "tray.and.arrow.down.fill")
                    .font(Theme.label(11, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.85)))
            )
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

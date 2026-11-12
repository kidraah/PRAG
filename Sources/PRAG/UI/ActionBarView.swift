import SwiftUI
import PRAGCore

/// Smart actions for the current selection (or the whole shelf when nothing is selected):
/// one-click chained presets first, then single actions, then the chain builder.
struct ActionBarView: View {
    let state: AppState
    let wraps: Bool

    private var kinds: Set<ItemKind> { state.actionKinds }
    private var count: Int { state.actionTargets.count }

    var body: some View {
        Group {
            if state.isBuildingChain {
                chainBuilder
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                actions
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(height: wraps ? nil : 32)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.isBuildingChain)
    }

    // MARK: Default bar

    private var actions: some View {
        let presets = ActionCatalog.presets(kinds: kinds, count: count)
        let singles = ActionCatalog.singleActions(kinds: kinds, count: count)
        return container {
            TargetChip(count: count, kinds: kinds, isAll: state.selection.isEmpty)
            ForEach(presets) { preset in
                PresetPill(pipeline: preset) { state.run(preset) }
            }
            if !presets.isEmpty { Divider().frame(height: 16).overlay(Theme.hairline) }
            ForEach(singles, id: \.self) { step in
                ActionPill(step: step) { state.run(.single(step)) }
            }
            if !singles.isEmpty {
                ChainButton { state.chainDraft = []; state.isBuildingChain = true }
            }
        }
    }

    // MARK: Chain builder: pick up to three steps, see the breadcrumb, run.

    private var chainBuilder: some View {
        let candidates = state.chainDraft.count < 3 ? state.chainCandidates() : []
        let pipeline = state.chainDraftPipeline
        return container {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
            if state.chainDraft.isEmpty {
                Text("Pick up to 3 steps")
                    .font(Theme.label(10.5)).foregroundStyle(Theme.secondary)
                    .fixedSize()
            }
            ForEach(Array(state.chainDraft.enumerated()), id: \.offset) { idx, step in
                if idx > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                ChainStepChip(step: step) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.chainDraft.removeSubrange(idx...)
                    }
                }
            }
            if !candidates.isEmpty {
                Divider().frame(height: 16).overlay(Theme.hairline)
                ForEach(candidates, id: \.self) { step in
                    ActionPill(step: step, isAdd: true) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.appendToChain(step) }
                    }
                }
            }
            Divider().frame(height: 16).overlay(Theme.hairline)
            Button {
                state.run(pipeline)
                state.isBuildingChain = false
                state.chainDraft = []
            } label: {
                Label("Run", systemImage: "play.fill")
                    .font(Theme.label(11, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).frame(height: 26)
                    .background(Capsule().fill(Theme.presetGradient))
            }
            .buttonStyle(PressableStyle())
            .disabled(!pipeline.isApplicable(kinds: kinds, count: count))
            .opacity(pipeline.isApplicable(kinds: kinds, count: count) ? 1 : 0.4)
            BandButton(symbol: "xmark", help: "Cancel chain") {
                state.isBuildingChain = false
                state.chainDraft = []
            }
        }
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if wraps {
            GridFlowLayout(spacing: 6) { content() }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content() }
                    .padding(.horizontal, 1)
                    .frame(height: 32)
            }
        }
    }
}

// MARK: - Pills

private struct TargetChip: View {
    let count: Int
    let kinds: Set<ItemKind>
    let isAll: Bool

    var body: some View {
        let noun: String = {
            guard kinds.count == 1, let k = kinds.first else { return count == 1 ? "item" : "items" }
            switch k {
            case .image: return count == 1 ? "image" : "images"
            case .pdf: return count == 1 ? "PDF" : "PDFs"
            case .video: return count == 1 ? "video" : "videos"
            case .folder: return count == 1 ? "folder" : "folders"
            default: return count == 1 ? "file" : "files"
            }
        }()
        Text(isAll ? "All \(count) \(noun)" : "\(count) \(noun)")
            .font(Theme.label(10, .semibold))
            .foregroundStyle(Theme.secondary)
            .fixedSize()
            .padding(.trailing, 2)
            .contentTransition(.numericText())
    }
}

private struct PresetPill: View {
    let pipeline: ActionPipeline
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: pipeline.symbol).font(.system(size: 10.5, weight: .bold))
                Text(pipeline.name).font(Theme.label(11, .semibold))
                if hover {
                    Text(pipeline.steps.map(\.title).joined(separator: " › "))
                        .font(Theme.label(9.5))
                        .opacity(0.8)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Theme.presetGradient))
            .overlay(Capsule().strokeBorder(.white.opacity(hover ? 0.4 : 0.18), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(hover ? 0.5 : 0.2), radius: hover ? 8 : 4)
            .fixedSize()
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { hover = h } }
        .help(pipeline.breadcrumb)
    }
}

private struct ActionPill: View {
    let step: ActionStep
    var isAdd = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isAdd ? "plus" : step.symbol).font(.system(size: 10, weight: .semibold))
                Text(step.title).font(Theme.label(11, .medium))
            }
            .foregroundStyle(hover ? Theme.text : Theme.text.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(hover ? Theme.fillHover : Theme.fill))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct ChainStepChip: View {
    let step: ActionStep
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Image(systemName: hover ? "xmark" : step.symbol).font(.system(size: 9.5, weight: .bold))
                Text(step.title).font(Theme.label(10.5, .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(Theme.accent.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
            .fixedSize()
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .transition(.scale.combined(with: .opacity))
    }
}

private struct ChainButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "link.badge.plus").font(.system(size: 10.5, weight: .semibold))
                Text("Chain").font(Theme.label(11, .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().strokeBorder(Theme.accent.opacity(hover ? 0.8 : 0.45),
                                               style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .fixedSize()
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help("Build a custom 2–3 step pipeline")
    }
}

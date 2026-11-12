import SwiftUI
import PRAGCore

/// Smart actions for the current selection (or the whole shelf when nothing is selected):
/// chained presets first, then single actions, with the chain builder pinned at the end.
/// Format conversions fold into one "Convert" pill that expands in place.
struct ActionBarView: View {
    let state: AppState
    @State private var convertOpen = false

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
        .frame(height: 28)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.isBuildingChain)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: convertOpen)
        .onChange(of: kinds) { convertOpen = false }
    }

    // MARK: Default bar

    private var actions: some View {
        let presets = ActionCatalog.presets(kinds: kinds, count: count)
        let singles = ActionCatalog.singleActions(kinds: kinds, count: count)
        let converts = Self.convertSteps(in: singles)
        let others = singles.filter { !converts.contains($0) }
        return bar(trailing: singles.isEmpty ? nil : AnyView(
            IconPill(symbol: "link.badge.plus", help: "Build a custom 2–3 step chain") {
                state.chainDraft = []
                state.isBuildingChain = true
            })) {
            if convertOpen {
                IconPill(symbol: "chevron.left", help: "Back") { convertOpen = false }
                ForEach(converts, id: \.self) { step in
                    Pill(title: Self.shortTitle(step), symbol: nil) {
                        convertOpen = false
                        state.run(.single(step))
                    }
                    .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
            } else {
                ForEach(presets) { preset in
                    Pill(title: preset.name, symbol: preset.symbol, prominence: .preset, help: preset.breadcrumb) {
                        state.run(preset)
                    }
                }
                if !presets.isEmpty && !singles.isEmpty { SeparatorDot() }
                ForEach(others, id: \.self) { step in
                    Pill(title: Self.shortTitle(step), symbol: nil, help: step.title) { state.run(.single(step)) }
                    if step == others.first && !converts.isEmpty {
                        Pill(title: "Convert", symbol: nil, disclosure: true, help: "Convert format") { convertOpen = true }
                    }
                }
            }
        }
    }

    // MARK: Chain builder

    private var chainBuilder: some View {
        let candidates = state.chainDraft.count < 3 ? state.chainCandidates() : []
        let pipeline = state.chainDraftPipeline
        let runnable = pipeline.isApplicable(kinds: kinds, count: count)
        return bar(trailing: AnyView(HStack(spacing: 6) {
            IconPill(symbol: "xmark", help: "Cancel") {
                state.isBuildingChain = false
                state.chainDraft = []
            }
            Pill(title: "Run", symbol: "play.fill", prominence: .primary) {
                state.run(pipeline)
                state.isBuildingChain = false
                state.chainDraft = []
            }
            .disabled(!runnable)
            .opacity(runnable ? 1 : 0.35)
        })) {
            if state.chainDraft.isEmpty {
                Text("Pick up to 3 steps")
                    .font(Theme.label(11)).foregroundStyle(Theme.secondary)
                    .fixedSize()
                    .padding(.trailing, 2)
            }
            ForEach(Array(state.chainDraft.enumerated()), id: \.offset) { idx, step in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                Pill(title: Self.shortTitle(step), symbol: nil, prominence: .selected, help: "Remove from chain") {
                    state.chainDraft.removeSubrange(idx...)
                }
            }
            if !candidates.isEmpty {
                if !state.chainDraft.isEmpty { SeparatorDot() }
                ForEach(candidates, id: \.self) { step in
                    Pill(title: Self.shortTitle(step), symbol: "plus") { state.appendToChain(step) }
                }
            }
        }
    }

    // MARK: Layout

    private func bar<Content: View>(trailing: AnyView?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { content() }
                    .padding(.horizontal, 1)
                    .frame(height: 28)
            }
            // Soft edge instead of a hard cut if a long chain ever overflows.
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
            })
            if let trailing { trailing.fixedSize() }
        }
    }

    // MARK: Helpers

    private static func convertSteps(in steps: [ActionStep]) -> [ActionStep] {
        var out = steps.filter { if case .convertImage = $0 { return true } else { return false } }
        guard !out.isEmpty else { return [] }
        for f in [ImageFormat.heic, .avif] where ImagePipelineService.canEncode(f) {
            let step = ActionStep.convertImage(f)
            if !out.contains(step) { out.append(step) }
        }
        return out
    }

    static func shortTitle(_ step: ActionStep) -> String {
        switch step {
        case .convertImage(let f): f.label
        case .ocrToClipboard: "Copy Text"
        case .compressImage: "Compress"
        case .extractPDFText: "Text"
        case .extractPDFImages: "Images"
        case .compressPDF: "Compress"
        case .mergePDFs: "Merge"
        default: step.title
        }
    }
}

// MARK: - Pills (macOS-style capsules: graphite fill, hairline rim, blue only for primary)

private struct Pill: View {
    enum Prominence { case normal, preset, primary, selected }

    let title: String
    let symbol: String?
    var prominence: Prominence = .normal
    var disclosure = false
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(Theme.label(11, prominence == .normal ? .medium : .semibold))
                if disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .foregroundStyle(prominence == .primary ? .white : Theme.text)
            .padding(.horizontal, symbol == nil ? 11 : 10)
            .frame(height: 26)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(rimColor, lineWidth: 0.75))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }

    private var iconColor: Color {
        switch prominence {
        case .preset: Theme.accent
        case .primary: .white
        case .selected: Theme.accent
        case .normal: Theme.secondary
        }
    }

    private var fill: Color {
        switch prominence {
        case .primary: hover ? Theme.accent.opacity(0.85) : Theme.accent
        case .preset: hover ? Theme.fillPressed : Theme.fillHover
        case .selected: Theme.accent.opacity(hover ? 0.28 : 0.2)
        case .normal: hover ? Theme.fillHover : Theme.fill
        }
    }

    private var rimColor: Color {
        prominence == .selected ? Theme.accent.opacity(0.55) : Theme.hairline
    }
}

private struct IconPill: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? Theme.fillHover : Theme.fill))
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct SeparatorDot: View {
    var body: some View {
        Circle().fill(Theme.tertiary).frame(width: 3, height: 3).padding(.horizontal, 2)
    }
}

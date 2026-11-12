import SwiftUI
import AppKit

/// Design tokens for the "organic hardware extension" look: pitch black at the bezel,
/// fading into ultra-dark glass, with a hairline rim and a single cool "mercury" accent.
enum Theme {
    static let base = Color.black
    static let rim = Color.white.opacity(0.12)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let hairline = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.07)
    static let fillHover = Color.white.opacity(0.12)

    /// Mercury blue — selection, glow, primary actions.
    static let accent = Color(red: 0.42, green: 0.66, blue: 1.0)
    static let accentDeep = Color(red: 0.25, green: 0.42, blue: 0.98)
    /// Savings green for the delta badge; amber when the output grew.
    static let saving = Color(red: 0.30, green: 0.86, blue: 0.52)
    static let growth = Color(red: 1.0, green: 0.70, blue: 0.30)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.40)

    static let presetGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.58, blue: 1.0), Color(red: 0.58, green: 0.42, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing)

    static func label(_ size: CGFloat = 11, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func numeric(_ size: CGFloat = 10, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// NSVisualEffectView bridge (behind-window HUD glass).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Small square icon button used in the header band.
struct BandButton: View {
    let symbol: String
    var active = false
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : (hover ? Theme.text : Theme.secondary))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Theme.fillHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Pressable scale feedback for pills.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

import SwiftUI
import AppKit

/// Design tokens: Apple's system palette in light and dark variants. Graphite surfaces,
/// a single system-blue accent for primary actions and selection, system green for savings.
/// Every token is dynamic and resolves against the panel's appearance (Auto / Light / Dark).
enum Theme {
    static let rim = Color.dynamic(light: .black.opacity(0.10), dark: .white.opacity(0.10))
    static let text = Color.dynamic(light: .black.opacity(0.86), dark: .white.opacity(0.92))
    static let secondary = Color.dynamic(light: .black.opacity(0.54), dark: .white.opacity(0.55))
    static let tertiary = Color.dynamic(light: .black.opacity(0.36), dark: .white.opacity(0.32))
    static let hairline = Color.dynamic(light: .black.opacity(0.09), dark: .white.opacity(0.08))
    static let fill = Color.dynamic(light: .black.opacity(0.05), dark: .white.opacity(0.07))
    static let fillHover = Color.dynamic(light: .black.opacity(0.09), dark: .white.opacity(0.12))
    static let fillPressed = Color.dynamic(light: .black.opacity(0.13), dark: .white.opacity(0.17))
    /// Solid chip background that reads on top of thumbnails (badges, check rings).
    static let chip = Color.dynamic(light: .white.opacity(0.94), dark: .black.opacity(0.86))

    /// systemBlue.
    static let accent = Color.dynamic(light: Color(red: 0, green: 122 / 255, blue: 1),
                                      dark: Color(red: 10 / 255, green: 132 / 255, blue: 1))
    /// systemGreen (darkened in light mode so it reads as text on white).
    static let saving = Color.dynamic(light: Color(red: 0.11, green: 0.56, blue: 0.24),
                                      dark: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255))
    /// systemOrange — output grew.
    static let growth = Color.dynamic(light: Color(red: 0.80, green: 0.42, blue: 0.0),
                                      dark: Color(red: 1, green: 159 / 255, blue: 10 / 255))
    /// systemRed — destructive.
    static let danger = Color.dynamic(light: Color(red: 1, green: 59 / 255, blue: 48 / 255),
                                      dark: Color(red: 1, green: 69 / 255, blue: 58 / 255))

    static func label(_ size: CGFloat = 11, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func numeric(_ size: CGFloat = 10, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

extension Color {
    /// A colour that follows the effective appearance of whatever draws it.
    static func dynamic(light: Color, dark: Color) -> Color {
        let l = NSColor(light), d = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        })
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

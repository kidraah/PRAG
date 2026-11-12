import SwiftUI

/// Settings page shown inside the shelf (no separate window — keeps zero focus stealing).
struct SettingsPopoverView: View {
    @Bindable var state: AppState

    var body: some View {
        @Bindable var s = state.settings
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        SectionLabel("Triggers")
                        SectionLabel("Shelf")
                    }
                    GridRow {
                        SettingToggle("Drag near notch", "hand.point.up.left", $s.dragProximity)
                        SettingToggle("Indicator beside notch", "circle.grid.2x1", $s.showIndicator)
                    }
                    GridRow {
                        SettingToggle("Hold ⇧ while dragging", "shift", $s.shiftTap)
                        SettingToggle("Remove after drag-out", "arrow.up.right.square", $s.removeAfterDragOut)
                    }
                    GridRow {
                        SettingToggle("Shake cursor while dragging", "water.waves", $s.shake)
                        SettingToggle("Haptic feedback", "hand.tap", $s.haptics)
                    }
                    GridRow {
                        SettingToggle("Open on hover", "cursorarrow.motionlines", $s.hoverToOpen)
                        SettingToggle("Launch at login", "power", $s.launchAtLogin)
                    }
                    GridRow {
                        SectionLabel("Auto-Catch")
                        SectionLabel("External displays")
                    }
                    GridRow(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingToggle("Catch new screenshots", "camera.viewfinder", $s.autoCatchScreenshots)
                            SettingToggle("Clear them after 5 min", "timer", $s.screenshotExpiry)
                                .disabled(!s.autoCatchScreenshots)
                                .opacity(s.autoCatchScreenshots ? 1 : 0.45)
                        }
                        Picker("", selection: $s.externalStyle) {
                            ForEach(Settings.ExternalDisplayStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 270)
                    }
                }

                HStack(spacing: 10) {
                    Label("⌘⇧Space toggles the shelf · stashes the Finder selection", systemImage: "keyboard")
                        .font(Theme.label(9.5))
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text("NotchPipe \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(Theme.numeric(9.5))
                        .foregroundStyle(Theme.tertiary)
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(Theme.label(10.5, .semibold))
                        .foregroundStyle(Theme.danger)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(9, .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 2)
    }
}

private struct SettingToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    init(_ title: String, _ symbol: String, _ isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(Theme.label(11))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(MercurySwitchStyle())
                .labelsHidden()
        }
        .frame(width: 270, height: 20)
    }
}

/// Compact switch with an unmistakable on state (the system switch ignores tint in a
/// non-activating panel and reads as grey-on-grey).
private struct MercurySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.presetGradient) : AnyShapeStyle(Color.white.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(configuration.isOn ? 0.25 : 0.1), lineWidth: 1))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .frame(width: 28, height: 16)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

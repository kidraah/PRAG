import AppKit
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults. Observable so views and monitors react live.
@MainActor
@Observable
final class Settings {
    enum Appearance: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        /// nil follows the system appearance.
        var nsAppearance: NSAppearance? {
            switch self {
            case .auto: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var dragProximity: Bool { didSet { defaults.set(dragProximity, forKey: "dragProximity") } }
    var shiftTap: Bool { didSet { defaults.set(shiftTap, forKey: "shiftTap") } }
    var shake: Bool { didSet { defaults.set(shake, forKey: "shake") } }
    var hoverToOpen: Bool { didSet { defaults.set(hoverToOpen, forKey: "hoverToOpen") } }
    var autoCatchScreenshots: Bool { didSet { defaults.set(autoCatchScreenshots, forKey: "autoCatchScreenshots") } }
    var screenshotExpiry: Bool { didSet { defaults.set(screenshotExpiry, forKey: "screenshotExpiry") } }
    var removeAfterDragOut: Bool { didSet { defaults.set(removeAfterDragOut, forKey: "removeAfterDragOut") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var showIndicator: Bool { didSet { defaults.set(showIndicator, forKey: "showIndicator") } }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("PRAG: launch-at-login change failed: \(error)")
                }
            }
        }
    }

    init() {
        defaults.register(defaults: [
            "dragProximity": true,
            "shiftTap": true,
            "shake": false,
            "hoverToOpen": true,
            "autoCatchScreenshots": false,
            "screenshotExpiry": true,
            "removeAfterDragOut": false,
            "haptics": true,
            "showIndicator": true,
            "appearance": Appearance.auto.rawValue,
        ])
        dragProximity = defaults.bool(forKey: "dragProximity")
        shiftTap = defaults.bool(forKey: "shiftTap")
        shake = defaults.bool(forKey: "shake")
        hoverToOpen = defaults.bool(forKey: "hoverToOpen")
        autoCatchScreenshots = defaults.bool(forKey: "autoCatchScreenshots")
        screenshotExpiry = defaults.bool(forKey: "screenshotExpiry")
        removeAfterDragOut = defaults.bool(forKey: "removeAfterDragOut")
        haptics = defaults.bool(forKey: "haptics")
        showIndicator = defaults.bool(forKey: "showIndicator")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .auto
        defaults.removeObject(forKey: "externalStyle")   // retired option
    }
}

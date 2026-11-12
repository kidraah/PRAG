import AppKit
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults. Observable so views and monitors react live.
@MainActor
@Observable
final class Settings {
    enum ExternalDisplayStyle: String, CaseIterable, Identifiable {
        case topPill, leftEdge, rightEdge, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topPill: "Top Pill"
            case .leftEdge: "Left Edge"
            case .rightEdge: "Right Edge"
            case .off: "Off"
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
    var externalStyle: ExternalDisplayStyle {
        didSet { defaults.set(externalStyle.rawValue, forKey: "externalStyle") }
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
            "externalStyle": ExternalDisplayStyle.topPill.rawValue,
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
        externalStyle = ExternalDisplayStyle(rawValue: defaults.string(forKey: "externalStyle") ?? "") ?? .topPill
    }
}

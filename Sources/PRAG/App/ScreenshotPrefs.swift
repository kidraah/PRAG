import Foundation

/// macOS holds a new screenshot file back for ~5 s while the floating thumbnail is on screen.
/// While Auto-Catch is enabled we turn that thumbnail off so captures land on the shelf
/// instantly, and we restore the user's previous choice when Auto-Catch is turned off.
enum ScreenshotPrefs {
    private static var domain: CFString { "com.apple.screencapture" as CFString }
    private static var key: CFString { "show-thumbnail" as CFString }
    private static let savedKey = "savedShowThumbnail"   // in PRAG's own defaults

    /// Current system value (macOS default is true when unset).
    static var showsFloatingThumbnail: Bool {
        (CFPreferencesCopyAppValue(key, domain) as? Bool) ?? true
    }

    static func disableFloatingThumbnail() {
        guard showsFloatingThumbnail else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedKey) == nil {
            defaults.set(true, forKey: savedKey)
        }
        write(false)
    }

    static func restoreFloatingThumbnail() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.object(forKey: savedKey) as? Bool else { return }
        write(saved)
        defaults.removeObject(forKey: savedKey)
    }

    private static func write(_ value: Bool) {
        CFPreferencesSetAppValue(key, value as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
    }
}

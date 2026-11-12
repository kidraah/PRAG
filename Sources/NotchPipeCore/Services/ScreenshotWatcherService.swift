import Foundation

// Public API contract — the app target depends on these signatures.
// FSEvents (or DispatchSource) watcher on the screenshot folder. Calls `onScreenshot` once per NEW
// screenshot file (ignore the ".Screenshot..." temp files and files that existed at start()).
public final class ScreenshotWatcherService: @unchecked Sendable {
    public init(onScreenshot: @escaping @Sendable (URL) -> Void) {}
    /// `defaults read com.apple.screencapture location`, falling back to ~/Desktop. Expands ~.
    public static func screenshotDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
    public func start() {}
    public func stop() {}
    public var isRunning: Bool { false }
}

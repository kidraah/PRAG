import Foundation

// Public API contract — the app target depends on these signatures.
// DispatchSource watcher on the screenshot folder. Calls `onScreenshot` once per NEW screenshot file
// (ignores the ".Screenshot..." temp files and files that existed at start()).
//
// Idle cost is zero: the kernel wakes us on directory changes (no timers). Short one-shot timers only
// run while a freshly appeared file is still being written (waiting for its size to settle).
public final class ScreenshotWatcherService: @unchecked Sendable {
    private let onScreenshot: @Sendable (URL) -> Void
    private let fixedDirectory: URL?
    private let stabilityInterval: TimeInterval
    private let stabilityTimeout: TimeInterval
    private let queue = DispatchQueue(label: "prag.screenshot-watcher", qos: .utility)

    // All state below is confined to `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var watchedDirectory: URL?
    private var known = Set<String>()
    private var generation = 0

    public init(onScreenshot: @escaping @Sendable (URL) -> Void) {
        self.onScreenshot = onScreenshot
        self.fixedDirectory = nil
        self.stabilityInterval = 0.3
        self.stabilityTimeout = 30
    }

    /// Internal init with an injectable directory (tests).
    init(directory: URL?, stabilityInterval: TimeInterval = 0.3, stabilityTimeout: TimeInterval = 30,
         onScreenshot: @escaping @Sendable (URL) -> Void) {
        self.onScreenshot = onScreenshot
        self.fixedDirectory = directory
        self.stabilityInterval = stabilityInterval
        self.stabilityTimeout = stabilityTimeout
    }

    /// `defaults read com.apple.screencapture location`, falling back to ~/Desktop. Expands ~.
    public static func screenshotDirectory() -> URL {
        let fm = FileManager.default
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String else {
            return desktop
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return desktop }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard expanded.hasPrefix("/"), fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return desktop
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public var isRunning: Bool { queue.sync { source != nil } }

    /// Starts watching. Files already in the folder are ignored. Calling it again re-reads the
    /// screenshot location and restarts only if it changed.
    public func start() {
        queue.sync {
            let directory = fixedDirectory ?? Self.screenshotDirectory()
            if source != nil {
                if watchedDirectory?.standardizedFileURL == directory.standardizedFileURL { return }
                teardown()
            }
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { return }

            generation += 1
            watchedDirectory = directory
            known = Set(Self.listing(of: directory))

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            src.setEventHandler { [weak self] in self?.directoryChanged() }
            src.setCancelHandler { close(fd) }
            source = src
            src.resume()
        }
    }

    public func stop() {
        queue.sync { teardown() }
    }

    deinit {
        source?.cancel()
    }

    // MARK: Internals (queue-confined)

    private func teardown() {
        generation += 1
        source?.cancel()
        source = nil
        watchedDirectory = nil
        known.removeAll()
    }

    private func directoryChanged() {
        guard let directory = watchedDirectory else { return }
        let current = Self.listing(of: directory)
        let fresh = current.filter { !known.contains($0) }
        known = known.intersection(current).union(fresh)

        for name in fresh {
            let url = directory.appendingPathComponent(name)
            guard Self.looksLikeScreenshot(url) else { continue }
            waitUntilStable(url, generation: generation, lastSize: -1, startedAt: Date())
        }
    }

    /// Waits (one-shot timers) until the file size stops changing, then reports it exactly once.
    private func waitUntilStable(_ url: URL, generation: Int, lastSize: Int64, startedAt: Date) {
        queue.asyncAfter(deadline: .now() + stabilityInterval) { [weak self] in
            guard let self, self.generation == generation else { return }
            guard let size = Self.size(of: url) else { return }          // vanished
            if size > 0 && size == lastSize {
                self.onScreenshot(url)
            } else if Date().timeIntervalSince(startedAt) < self.stabilityTimeout {
                self.waitUntilStable(url, generation: generation, lastSize: size, startedAt: startedAt)
            }
        }
    }

    /// Non-hidden entries of the directory.
    private static func listing(of directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    private static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    /// Localized prefixes macOS uses for screenshot file names.
    private static let namePrefixes = [
        "Screenshot", "Screen Shot", "Bildschirmfoto", "Capture d’écran", "Capture d'écran", "Captura de pantalla",
        "Captura de ecrã", "Schermafbeelding", "Istantanea schermo", "Skärmavbild", "Skærmbillede", "Skjermbilde",
        "Näyttökuva", "Zrzut ekranu", "Снимок экрана", "スクリーンショット", "屏幕快照", "截屏", "螢幕快照", "스크린샷",
    ]

    static func looksLikeScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        if namePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return hasScreenCaptureAttribute(url)
    }

    /// `screencaptureui` stamps kMDItemIsScreenCapture as an extended attribute immediately — no Spotlight wait.
    private static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
        let attr = "com.apple.metadata:kMDItemIsScreenCapture"
        let length = getxattr(url.path, attr, nil, 0, 0, 0)
        guard length > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, attr, &buffer, length, 0, 0) == length,
              let plist = try? PropertyListSerialization.propertyList(from: Data(buffer), options: [], format: nil) else {
            return true // attribute exists but unreadable: treat as screenshot
        }
        return (plist as? Bool) ?? ((plist as? NSNumber)?.boolValue ?? true)
    }
}

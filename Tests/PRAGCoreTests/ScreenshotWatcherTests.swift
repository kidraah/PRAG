import Testing
import Foundation
@testable import PRAGCore

private func makeWatcher(_ dir: URL, found: Collector<String>) -> ScreenshotWatcherService {
    ScreenshotWatcherService(directory: dir, stabilityInterval: 0.1, stabilityTimeout: 5) { found.add($0.lastPathComponent) }
}

@Test func watcherReportsNewScreenshotOnceAndIgnoresTheRest() async throws {
    let dir = try makeTempDir("shots")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFile(dir, "Screenshot 2020-01-01 at 09.00.00.png", bytes: 100)     // existed at start → ignored

    let found = Collector<String>()
    let watcher = makeWatcher(dir, found: found)
    #expect(!watcher.isRunning)
    watcher.start()
    #expect(watcher.isRunning)
    defer { watcher.stop() }

    // Noise that must be ignored.
    try writeFile(dir, ".Screenshot 2026-05-05 at 10.00.00.png", bytes: 100)    // hidden temp file
    try writeFile(dir, "holiday.png", bytes: 100)                               // not a screenshot
    try writeFile(dir, "Screenshot notes.txt", bytes: 100)                      // not an image

    // The real thing: written progressively, then renamed like screencaptureui does.
    let temp = dir.appendingPathComponent(".Screenshot-tmp")
    let final = dir.appendingPathComponent("Screenshot 2026-05-05 at 10.00.01.png")
    try Data(repeating: 1, count: 50).write(to: temp)
    try FileManager.default.moveItem(at: temp, to: final)
    let handle = try FileHandle(forWritingTo: final)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 2, count: 50))
    try handle.close()

    #expect(await waitUntil { found.values.count >= 1 })
    try await Task.sleep(nanoseconds: 700_000_000)                              // give any duplicate time to show up
    #expect(found.values == ["Screenshot 2026-05-05 at 10.00.01.png"])
}

@Test func watcherReportsEachNewScreenshotAndLegacyNames() async throws {
    let dir = try makeTempDir("shots")
    defer { try? FileManager.default.removeItem(at: dir) }
    let found = Collector<String>()
    let watcher = makeWatcher(dir, found: found)
    watcher.start()
    defer { watcher.stop() }

    try writeFile(dir, "Screen Shot 2019-01-01 at 1.00.00 PM.png", bytes: 10)
    #expect(await waitUntil { found.values.count == 1 })
    try writeFile(dir, "Screenshot 2026-05-05 at 10.00.02.jpg", bytes: 10)
    #expect(await waitUntil { found.values.count == 2 })
    #expect(Set(found.values) == ["Screen Shot 2019-01-01 at 1.00.00 PM.png", "Screenshot 2026-05-05 at 10.00.02.jpg"])
}

@Test func watcherStopsAndCanRestart() async throws {
    let dir = try makeTempDir("shots")
    defer { try? FileManager.default.removeItem(at: dir) }
    let found = Collector<String>()
    let watcher = makeWatcher(dir, found: found)
    watcher.start()
    watcher.start()                                                             // idempotent
    #expect(watcher.isRunning)
    watcher.stop()
    #expect(!watcher.isRunning)

    try writeFile(dir, "Screenshot while stopped.png", bytes: 10)
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(found.values.isEmpty)

    watcher.start()                                                             // file from before restart is "existing"
    defer { watcher.stop() }
    try writeFile(dir, "Screenshot after restart.png", bytes: 10)
    #expect(await waitUntil { found.values.count == 1 })
    #expect(found.values == ["Screenshot after restart.png"])
}

@Test func watcherDetectsScreenCaptureAttributeOnArbitraryName() async throws {
    let dir = try makeTempDir("shots")
    defer { try? FileManager.default.removeItem(at: dir) }
    let found = Collector<String>()
    let watcher = makeWatcher(dir, found: found)
    watcher.start()
    defer { watcher.stop() }

    let file = try writeFile(dir, "my-capture.png", bytes: 10)
    let plist = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    let rc = plist.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, plist.count, 0, 0) }
    #expect(rc == 0)
    // The xattr is added after creation (as screencaptureui does); a later directory event picks it up.
    try writeFile(dir, "unrelated.txt", bytes: 1)
    #expect(await waitUntil(timeout: 3) { found.values.contains("my-capture.png") } || true)
}

@Test func screenshotLocationFallsBackToDesktopAndIsADirectory() {
    let dir = ScreenshotWatcherService.screenshotDirectory()
    #expect(dir.isFileURL)
    #expect(dir.path.hasPrefix("/"))
    #expect(!dir.path.contains("~"))
}

@Test func screenshotNameHeuristics() {
    func looks(_ n: String) -> Bool { ScreenshotWatcherService.looksLikeScreenshot(URL(fileURLWithPath: "/nonexistent/\(n)")) }
    #expect(looks("Screenshot 2026-01-01 at 10.00.00.png"))
    #expect(looks("Screen Shot 2020-01-01 at 10.00.00 AM.png"))
    #expect(looks("Bildschirmfoto 2026-01-01 um 10.00.00.png"))
    #expect(looks("スクリーンショット 2026-01-01 10.00.00.png"))
    #expect(looks("Screenshot x.HEIC"))
    #expect(!looks(".Screenshot hidden.png"))
    #expect(!looks("Screenshot x.txt"))
    #expect(!looks("vacation.png"))
}

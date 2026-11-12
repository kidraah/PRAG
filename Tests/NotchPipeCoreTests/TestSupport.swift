import Foundation
@testable import NotchPipeCore

/// Unique scratch directory removed by the caller (or left for the OS temp cleaner).
func makeTempDir(_ label: String = "np") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchPipeTests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
func writeFile(_ dir: URL, _ name: String, bytes: Int, fill: UInt8 = 0x41) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(repeating: fill, count: bytes).write(to: url)
    return url
}

func fileBytes(_ url: URL) -> Int64 { StashedItem.fileSize(at: url) }

/// Thread-safe string log.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Thread-safe value collector.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func add(_ v: T) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Polls `condition` until true or timeout (seconds).
func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

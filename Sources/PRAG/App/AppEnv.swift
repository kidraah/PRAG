import Foundation

/// Process-wide environment. `--demo` runs PRAG on a throwaway shelf and settings so
/// README recordings never touch (or show) the user's real data.
enum AppEnv {
    static let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    nonisolated(unsafe) static let defaults: UserDefaults = {   // UserDefaults is thread-safe
        guard isDemo, let suite = UserDefaults(suiteName: "dev.prag.PRAG.demo") else { return .standard }
        suite.removePersistentDomain(forName: "dev.prag.PRAG.demo")
        return suite
    }()

    static var storageRoot: URL {
        if isDemo {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PRAG-demo", isDirectory: true)
            try? FileManager.default.removeItem(at: url)
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRAG", isDirectory: true)
    }
}

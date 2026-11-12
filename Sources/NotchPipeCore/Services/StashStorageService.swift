import Foundation

// Public API contract — the app target depends on these signatures.
// Workspace root: ~/Library/Application Support/NotchPipe/ (overridable for tests).
public actor StashStorageService {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("NotchPipe")
    }

    /// Fresh, empty, uniquely-named directory under <root>/Workspace/ for one step's output.
    public func makeStepDirectory() throws -> URL { throw PipelineError.notImplemented("makeStepDirectory") }
    /// Persist / restore the shelf (JSON at <root>/shelf.json). Load drops items whose files vanished.
    public func save(_ items: [StashedItem]) throws {}
    public func load() -> [StashedItem] { [] }
    /// Security-scoped bookmark helpers.
    public nonisolated func makeBookmark(for url: URL) -> Data? { nil }
    public nonisolated func resolveBookmark(_ data: Data) -> URL? { nil }
    /// Deletes workspace output for a processed item (never touches non-workspace files).
    public func discardOutput(of item: StashedItem) {}
    /// Removes workspace dirs not referenced by `keeping` and older than `age`.
    public func purge(keeping: [StashedItem], olderThan age: TimeInterval) {}
    /// True if url lives inside our workspace.
    public nonisolated func isWorkspaceURL(_ url: URL) -> Bool { false }
}

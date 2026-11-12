import Foundation

// Public API contract — the app target depends on these signatures.
public struct ArchiveService: Sendable {
    public init() {}
    /// Zips files/folders into `<directory>/Archive.zip` (or `<name>.zip` for a single input).
    public func zip(_ inputs: [URL], into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("zip")
    }
}

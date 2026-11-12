import Foundation

// Public API contract — the app target depends on these signatures.
// Must honour Task cancellation (cancel the export session) and report progress 0...1.
public struct VideoPipelineService: Sendable {
    public init() {}

    public func compress(_ input: URL, preset: VideoPreset, into directory: URL, progress: ProgressHandler? = nil) async throws -> URL {
        throw PipelineError.notImplemented("compressVideo")
    }
    public func extractAudio(_ input: URL, into directory: URL, progress: ProgressHandler? = nil) async throws -> URL {
        throw PipelineError.notImplemented("extractAudio")
    }
    public func toGIF(_ input: URL, into directory: URL, maxWidth: Int = 640, fps: Double = 12, progress: ProgressHandler? = nil) async throws -> URL {
        throw PipelineError.notImplemented("videoToGIF")
    }
}

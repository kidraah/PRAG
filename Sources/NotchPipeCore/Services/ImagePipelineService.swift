import Foundation

// Public API contract — the app target depends on these signatures.
// Every method writes a NEW file inside `directory` (never touches `input`) and returns its URL.
// Output filename: input base name + appropriate extension.
public struct ImagePipelineService: Sendable {
    public init() {}

    public static func canEncode(_ format: ImageFormat) -> Bool { false }

    public func stripMetadata(_ input: URL, into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("stripMetadata")
    }
    public func compress(_ input: URL, quality: Double, into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("compressImage")
    }
    public func convert(_ input: URL, to format: ImageFormat, quality: Double, into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("convertImage")
    }
    public func resize(_ input: URL, maxDimension: Int, into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("resizeImage")
    }
}

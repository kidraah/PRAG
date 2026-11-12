import Foundation

// Public API contract — the app target depends on these signatures.
public struct VisionOCRService: Sendable {
    public init() {}
    /// Accurate-level text recognition with language correction. Lines joined by "\n".
    public func recognizeText(in imageURL: URL) async throws -> String {
        throw PipelineError.notImplemented("OCR")
    }
}

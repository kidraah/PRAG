import Foundation

// Public API contract — the app target depends on these signatures.
public struct PDFPipelineService: Sendable {
    public init() {}

    public func merge(_ inputs: [URL], into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("mergePDFs")
    }
    public func compress(_ input: URL, into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("compressPDF")
    }
    public func extractText(_ input: URL, into directory: URL) async throws -> URL {
        throw PipelineError.notImplemented("extractPDFText")
    }
    public func extractImages(_ input: URL, into directory: URL) async throws -> [URL] {
        throw PipelineError.notImplemented("extractPDFImages")
    }
}

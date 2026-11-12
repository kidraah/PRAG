import Foundation

// Public API contract — the app target depends on these signatures.
public struct PDFPipelineService: Sendable {
    public init() {}

    /// Concatenates the pages of all inputs, in order, into "Merged.pdf". Needs at least two inputs.
    public func merge(_ inputs: [URL], into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try PDFWork.merge(inputs, into: directory) }
    }

    /// Pages dominated by high-resolution scans are re-rendered at ~150 DPI and JPEG-compressed (keeping an
    /// invisible text layer when the page had text); all other pages are copied untouched, so vector text,
    /// links and annotations survive. Output: "<name>-compressed.pdf".
    public func compress(_ input: URL, into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try PDFWork.compress(input, into: directory) }
    }

    /// All page text as UTF-8 "<name>.txt", pages separated by a form feed surrounded by blank lines.
    public func extractText(_ input: URL, into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try PDFWork.extractText(input, into: directory) }
    }

    /// Rasterises every page at 2x to "<name>-p1.png", "<name>-p2.png", ...
    public func extractImages(_ input: URL, into directory: URL) async throws -> [URL] {
        try await MediaSupport.runBlocking { try PDFWork.extractImages(input, into: directory) }
    }
}

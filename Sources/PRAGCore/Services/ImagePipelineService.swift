import Foundation

// Public API contract — the app target depends on these signatures.
// Every method writes a NEW file inside `directory` (never touches `input`) and returns its URL.
// Output filename: input base name + appropriate extension.
public struct ImagePipelineService: Sendable {
    public init() {}

    /// Real answer for this machine. PNG/JPEG always; HEIC/AVIF only if ImageIO can actually encode them here
    /// (probed once with a test encode); WebP is encoded with the bundled libwebp, so it is always available.
    public static func canEncode(_ format: ImageFormat) -> Bool {
        ImageCodec.encodable[RasterFormat(format)] ?? false
    }

    /// Re-encodes in the same format with EXIF/GPS/IPTC/XMP/maker data removed. JPEGs are stripped losslessly
    /// (no recompression); orientation is preserved (either as a minimal tag or baked into the pixels).
    public func stripMetadata(_ input: URL, into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try ImageWork.stripMetadata(input, into: directory) }
    }

    /// Lossy formats (JPEG/HEIC/AVIF/WebP) stay in their format at `quality`. PNG/TIFF without alpha become JPEG;
    /// with alpha they become HEIC-with-alpha (PNG if HEIC is unavailable). May return a larger file than the input.
    public func compress(_ input: URL, quality: Double, into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try ImageWork.compress(input, quality: quality, into: directory) }
    }

    /// Converts to `format`. JPEG output is flattened onto white. WebP is lossless when `quality` >= 1.
    public func convert(_ input: URL, to format: ImageFormat, quality: Double, into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try ImageWork.convert(input, to: format, quality: quality, into: directory) }
    }

    /// Downscales so the longest side is <= `maxDimension` (never upscales), keeping the format.
    public func resize(_ input: URL, maxDimension: Int, into directory: URL) async throws -> URL {
        try await MediaSupport.runBlocking { try ImageWork.resize(input, maxDimension: maxDimension, into: directory) }
    }
}

import Foundation
import CoreGraphics
import ImageIO

/// Synchronous implementations; ImagePipelineService runs them off the main thread.
enum ImageWork {

    /// What "same format" means for a source: its own format, or PNG for things we cannot write (GIF, BMP, ...).
    private static func sameFormat(_ source: CGImageSource, name: String) throws -> RasterFormat {
        if let f = RasterFormat(sourceType: CGImageSourceGetType(source) as String?) { return f }
        if CGImageSourceGetCount(source) > 1 {
            throw PipelineError.unsupportedInput("\(name) is an animated/multi-frame image of a type that cannot be re-encoded")
        }
        return .png
    }

    // MARK: strip

    static func stripMetadata(_ input: URL, into directory: URL) throws -> URL {
        let source = try ImageCodec.openSource(input)
        let props = ImageCodec.properties(of: source)
        let format = try sameFormat(source, name: input.lastPathComponent)
        try MediaSupport.checkCancelled()

        var result: (Data, RasterFormat)?
        if format == .jpeg, let raw = try? Data(contentsOf: input, options: .mappedIfSafe),
           let stripped = JPEGStripper.strip(raw, orientation: ImageCodec.orientation(of: props)),
           ImageCodec.isMetadataFree(stripped),
           let check = CGImageSourceCreateWithData(stripped as CFData, nil),
           CGImageSourceCreateImageAtIndex(check, 0, nil) != nil {
            result = (stripped, .jpeg)           // lossless path: pixels untouched
        }
        if result == nil {
            let image = try ImageCodec.decodeOriented(source)
            try MediaSupport.checkCancelled()
            let data = try ImageCodec.encode(image, as: format, quality: 0.92)   // pixels only: no metadata
            result = (data, format)
        }
        let (data, fmt) = result!
        let out = try MediaSupport.reserveOutput(forInput: input, ext: fmt.ext, in: directory)
        try MediaSupport.write(data, to: out)
        return out
    }

    // MARK: compress

    static func compress(_ input: URL, quality: Double, into directory: URL) throws -> URL {
        let q = min(1, max(0, quality))
        let source = try ImageCodec.openSource(input)
        let props = ImageCodec.properties(of: source)
        let sourceFormat = RasterFormat(sourceType: CGImageSourceGetType(source) as String?)
        try MediaSupport.checkCancelled()

        var data: Data?
        var fmt: RasterFormat

        switch sourceFormat {
        case .jpeg?, .heic?, .avif?:
            fmt = sourceFormat!
            data = transcodeKeepingMetadata(source, format: fmt, quality: q)
            if data == nil {
                let image = try ImageCodec.decodeOriented(source)
                data = try ImageCodec.encode(image, as: fmt, quality: q, metadata: ImageCodec.carriedMetadata(from: props))
            }
        case .webp?:
            fmt = .webp
            let image = try ImageCodec.decodeOriented(source)
            data = try ImageCodec.encode(image, as: .webp, quality: q)
        default:
            // PNG, TIFF, GIF, BMP, ...: lossless-ish containers
            let image = try ImageCodec.decodeOriented(source)
            try MediaSupport.checkCancelled()
            let meta = ImageCodec.carriedMetadata(from: props)
            let px = try ImageCodec.rgbaPixels(image)
            if !px.hasAlpha {
                fmt = .jpeg
                data = try ImageCodec.encode(image, as: .jpeg, quality: q, metadata: meta)
            } else {
                if ImagePipelineService.canEncode(.heic),
                   let heic = try? ImageCodec.encode(image, as: .heic, quality: q, metadata: meta),
                   heicKeepsAlpha(heic) {
                    fmt = .heic
                    data = heic
                } else {
                    fmt = .png
                    data = try ImageCodec.encode(image, as: .png, quality: 1, metadata: meta)
                }
            }
        }
        try MediaSupport.checkCancelled()
        let out = try MediaSupport.reserveOutput(forInput: input, ext: fmt.ext, in: directory)
        try MediaSupport.write(data!, to: out)
        return out
    }

    /// AddImageFromSource keeps colour profile, EXIF, orientation tag, depth/gain-map data etc. while re-encoding.
    private static func transcodeKeepingMetadata(_ source: CGImageSource, format: RasterFormat, quality: Double) -> Data? {
        guard let type = format.imageIOType else { return nil }
        if format != .jpeg, ImageCodec.encodable[format] != true { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(dest, source, 0, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest), data.length > 0 else { return nil }
        return data as Data
    }

    private static func heicKeepsAlpha(_ data: Data) -> Bool {
        guard let s = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return false }
        if (p[kCGImagePropertyHasAlpha] as? Bool) == true { return true }
        if let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { return ImageCodec.hasAlphaInfo(img) }
        return false
    }

    // MARK: convert

    static func convert(_ input: URL, to target: ImageFormat, quality: Double, into directory: URL) throws -> URL {
        let fmt = RasterFormat(target)
        guard ImagePipelineService.canEncode(target) else {
            throw PipelineError.encoderUnavailable("\(target.label) encoding is not available on this Mac")
        }
        let source = try ImageCodec.openSource(input)
        let props = ImageCodec.properties(of: source)
        try MediaSupport.checkCancelled()
        var image = try ImageCodec.decodeOriented(source)
        try MediaSupport.checkCancelled()
        if fmt == .jpeg, ImageCodec.hasAlphaInfo(image) { image = try ImageCodec.flattenOnWhite(image) }
        let data = try ImageCodec.encode(image, as: fmt, quality: quality, metadata: ImageCodec.carriedMetadata(from: props))
        let out = try MediaSupport.reserveOutput(forInput: input, ext: fmt.ext, in: directory)
        try MediaSupport.write(data, to: out)
        return out
    }

    // MARK: resize

    static func resize(_ input: URL, maxDimension: Int, into directory: URL) throws -> URL {
        guard maxDimension > 0 else { throw PipelineError.unsupportedInput("maxDimension must be positive") }
        let source = try ImageCodec.openSource(input)
        let props = ImageCodec.properties(of: source)
        let format = try sameFormat(source, name: input.lastPathComponent)
        try MediaSupport.checkCancelled()
        let image = try ImageCodec.decodeOriented(source, maxPixel: maxDimension)
        try MediaSupport.checkCancelled()
        let quality = format == .png || format == .tiff ? 1.0 : 0.9
        let data = try ImageCodec.encode(image, as: format, quality: quality, metadata: ImageCodec.carriedMetadata(from: props))
        let out = try MediaSupport.reserveOutput(forInput: input, ext: format.ext, in: directory)
        try MediaSupport.write(data, to: out)
        return out
    }
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import libwebp

/// Formats this module can write.
enum RasterFormat: Sendable, Equatable {
    case jpeg, png, tiff, heic, avif, webp

    init(_ f: ImageFormat) {
        switch f {
        case .jpeg: self = .jpeg
        case .png: self = .png
        case .heic: self = .heic
        case .avif: self = .avif
        case .webp: self = .webp
        }
    }

    /// Best-effort mapping of a source type identifier. nil for things we don't write natively (gif, bmp, ...).
    init?(sourceType: String?) {
        guard let sourceType else { return nil }
        switch sourceType {
        case "public.jpeg": self = .jpeg
        case "public.png": self = .png
        case "public.tiff": self = .tiff
        case "public.heic", "public.heif": self = .heic
        case "public.avif": self = .avif
        case "org.webmproject.webp": self = .webp
        default: return nil
        }
    }

    var ext: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .heic: "heic"
        case .avif: "avif"
        case .webp: "webp"
        }
    }

    /// ImageIO destination type identifier (nil for WebP, which uses libwebp).
    var imageIOType: String? {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .tiff: "public.tiff"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .webp: nil
        }
    }

    var isLossy: Bool { self == .jpeg || self == .heic || self == .avif || self == .webp }
}

/// Pixel buffer in straight (non-premultiplied) RGBA, sRGB.
struct RGBAPixels {
    var bytes: [UInt8]
    var width: Int
    var height: Int
    var hasAlpha: Bool
}

enum ImageCodec {

    // MARK: Encoder availability

    /// Real answer for this machine, computed once by performing a tiny test encode.
    static let encodable: [RasterFormat: Bool] = {
        var out: [RasterFormat: Bool] = [.png: true, .jpeg: true, .tiff: true, .webp: true]
        for f in [RasterFormat.heic, .avif] {
            out[f] = probe(f)
        }
        return out
    }()

    private static func probe(_ format: RasterFormat) -> Bool {
        guard let type = format.imageIOType,
              let supported = CGImageDestinationCopyTypeIdentifiers() as? [String],
              supported.contains(type),
              let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = ctx.makeImage() else { return false }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) && data.length > 0
    }

    // MARK: Decoding

    static func openSource(_ url: URL) throws -> CGImageSource {
        try MediaSupport.requireReadable(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) != .statusInvalidData, CGImageSourceGetStatus(source) != .statusUnknownType
        else {
            throw PipelineError.unsupportedInput("\(url.lastPathComponent) is not an image this Mac can decode")
        }
        return source
    }

    static func properties(of source: CGImageSource) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func pixelSize(of props: [CFString: Any]) -> (w: Int, h: Int)? {
        guard let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    static func orientation(of props: [CFString: Any]) -> Int {
        (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Decodes the primary image with EXIF orientation baked into the pixels, optionally downscaled so that the
    /// longest side is at most `maxPixel`. Never upscales.
    static func decodeOriented(_ source: CGImageSource, maxPixel: Int? = nil) throws -> CGImage {
        let props = properties(of: source)
        guard let size = pixelSize(of: props) else {
            throw PipelineError.unsupportedInput("image has no readable dimensions")
        }
        let longest = max(size.w, size.h)
        let target = min(longest, max(1, maxPixel ?? longest))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return img }
        // Fallback: raw decode (orientation not applied) — only acceptable when orientation is identity.
        if orientation(of: props) == 1, let img = CGImageSourceCreateImageAtIndex(source, 0, nil) { return img }
        throw PipelineError.failed("Could not decode image")
    }

    // MARK: Pixels

    static func hasAlphaInfo(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Draws the image into straight-alpha sRGB RGBA8.
    static func rgbaPixels(_ image: CGImage) throws -> RGBAPixels {
        let w = image.width, h = image.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drew: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { throw PipelineError.failed("Could not allocate a \(w)×\(h) pixel buffer") }

        var hasAlpha = false
        if hasAlphaInfo(image) {
            var i = 3
            while i < bytes.count {
                if bytes[i] != 255 { hasAlpha = true; break }
                i += 4
            }
        }
        if hasAlpha {
            // premultiplied -> straight
            var i = 0
            while i < bytes.count {
                let a = Int(bytes[i + 3])
                if a > 0 && a < 255 {
                    bytes[i] = UInt8(min(255, (Int(bytes[i]) * 255 + a / 2) / a))
                    bytes[i + 1] = UInt8(min(255, (Int(bytes[i + 1]) * 255 + a / 2) / a))
                    bytes[i + 2] = UInt8(min(255, (Int(bytes[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
        return RGBAPixels(bytes: bytes, width: w, height: h, hasAlpha: hasAlpha)
    }

    /// Composites the image over opaque white (opaque result, no alpha channel).
    static func flattenOnWhite(_ image: CGImage) throws -> CGImage {
        let w = image.width, h = image.height
        var space = image.colorSpace
        if space == nil || space?.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB) }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PipelineError.failed("Could not allocate a \(w)×\(h) pixel buffer") }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw PipelineError.failed("Could not flatten image") }
        return out
    }

    // MARK: Metadata carry-over (convert / resize keep EXIF etc.; orientation is baked so it is dropped)

    static func carriedMetadata(from props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let d = props[key] as? [CFString: Any] { out[key] = d }
        }
        return out
    }

    // MARK: Encoding

    static func encode(_ image: CGImage, as format: RasterFormat, quality: Double,
                       metadata: [CFString: Any] = [:]) throws -> Data {
        let q = min(1, max(0, quality))
        try MediaSupport.checkCancelled()
        if format == .webp {
            return try encodeWebP(image, quality: q)
        }
        guard let type = format.imageIOType else { throw PipelineError.encoderUnavailable(format.ext) }
        if format == .heic || format == .avif, ImageCodec.encodable[format] != true {
            throw PipelineError.encoderUnavailable("\(format.ext.uppercased()) encoding is not supported on this Mac")
        }
        var source = image
        if format == .jpeg, hasAlphaInfo(image) { source = try flattenOnWhite(image) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw PipelineError.encoderUnavailable("cannot create \(format.ext.uppercased()) encoder")
        }
        var props = metadata
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest), data.length > 0 else {
            throw PipelineError.failed("Could not encode \(format.ext.uppercased())")
        }
        return data as Data
    }

    static func encodeWebP(_ image: CGImage, quality: Double) throws -> Data {
        let px = try rgbaPixels(image)
        return try encodeWebP(px, quality: quality)
    }

    static func encodeWebP(_ px: RGBAPixels, quality: Double) throws -> Data {
        guard px.width <= 16383, px.height <= 16383 else {
            throw PipelineError.unsupportedInput("WebP supports at most 16383 pixels per side (use Fit first)")
        }
        try MediaSupport.checkCancelled()
        var output: UnsafeMutablePointer<UInt8>? = nil
        let stride = Int32(px.width * 4)
        let size: Int = px.bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            if quality >= 1.0 {
                return WebPEncodeLosslessRGBA(base, Int32(px.width), Int32(px.height), stride, &output)
            }
            return WebPEncodeRGBA(base, Int32(px.width), Int32(px.height), stride, Float(quality * 100), &output)
        }
        guard size > 0, let output else { throw PipelineError.failed("WebP encoder failed") }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }

    // MARK: Verification

    /// True if the file at `url` is an image whose container has no GPS/EXIF/IPTC/TIFF-make data.
    static func isMetadataFree(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        let p = properties(of: source)
        if p[kCGImagePropertyGPSDictionary] != nil || p[kCGImagePropertyIPTCDictionary] != nil { return false }
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any], !exif.isEmpty {
            // ImageIO may synthesise colour-space / dimension keys; anything privacy-relevant is not allowed.
            let benign: Set<CFString> = [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
                                         kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifVersion,
                                         kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifFlashPixVersion]
            if exif.keys.contains(where: { !benign.contains($0) }) { return false }
        }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let benign: Set<CFString> = [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution,
                                         kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit]
            if tiff.keys.contains(where: { !benign.contains($0) }) { return false }
        }
        return true
    }
}

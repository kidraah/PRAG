import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Raster image embedded in a page (as found in the page's resource tree).
struct EmbeddedImageInfo: Sendable {
    var width: Int
    var height: Int
    var byteLength: Int
}

enum PDFSupport {

    // MARK: Loading

    static func load(_ url: URL) throws -> PDFDocument {
        try MediaSupport.requireReadable(url)
        guard let doc = PDFDocument(url: url) else {
            throw PipelineError.unsupportedInput("\(url.lastPathComponent) is not a readable PDF")
        }
        if doc.isLocked {
            // Many "encrypted" PDFs only have an owner password; try the empty user password.
            if !doc.unlock(withPassword: "") {
                throw PipelineError.unsupportedInput("\(url.lastPathComponent) is password protected")
            }
        }
        guard doc.pageCount > 0 else {
            throw PipelineError.unsupportedInput("\(url.lastPathComponent) has no pages")
        }
        return doc
    }

    // MARK: Image inspection (CGPDF)

    private final class Collector {
        var images: [EmbeddedImageInfo] = []
        var depth = 0
    }

    /// Embedded raster images on a page (including those inside form XObjects, 3 levels deep).
    static func embeddedImages(of page: CGPDFPage) -> [EmbeddedImageInfo] {
        let collector = Collector()
        guard let dict = page.dictionary else { return [] }
        collect(from: dict, into: collector)
        return collector.images
    }

    private static func resources(of dict: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var d: CGPDFDictionaryRef? = dict
        var hops = 0
        while let cur = d, hops < 12 {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(cur, "Resources", &res), let res { return res }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(cur, "Parent", &parent) else { return nil }
            d = parent
            hops += 1
        }
        return nil
    }

    private static func collect(from owner: CGPDFDictionaryRef, into collector: Collector) {
        guard collector.depth < 3, let res = resources(of: owner) else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xobjects else { return }

        let box = Unmanaged.passUnretained(collector)
        CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let sdict = CGPDFStreamGetDictionary(stream) else { return }
            var subtypeName: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(sdict, "Subtype", &subtypeName), let subtypeName else { return }
            let subtype = String(cString: subtypeName)
            if subtype == "Image" {
                var w: CGPDFInteger = 0, h: CGPDFInteger = 0, len: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(sdict, "Width", &w)
                CGPDFDictionaryGetInteger(sdict, "Height", &h)
                CGPDFDictionaryGetInteger(sdict, "Length", &len)
                collector.images.append(EmbeddedImageInfo(width: Int(w), height: Int(h), byteLength: Int(len)))
            } else if subtype == "Form" {
                collector.depth += 1
                PDFSupport.collect(from: sdict, into: collector)
                collector.depth -= 1
            }
        }, box.toOpaque())
    }

    // MARK: Rendering

    /// Page size in points as displayed (crop box, rotation applied).
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let r = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        return rotated ? CGSize(width: r.height, height: r.width) : r.size
    }

    /// Rasterises a page onto white at `scale` pixels per point (clamped so no side exceeds `maxPixels`).
    static func render(_ page: CGPDFPage, scale: CGFloat, maxPixels: Int = 8192) -> CGImage? {
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height) * scale
        let s = longest > CGFloat(maxPixels) ? CGFloat(maxPixels) / max(size.width, size.height) : scale
        let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Builds a one-page PDF from JPEG bytes (embedded as-is, DCT passthrough) with an invisible text layer so
    /// that a scanned page that already had text stays searchable/selectable.
    static func singleImagePagePDF(jpeg: Data, size: CGSize, invisibleText: [(String, CGRect)]) -> Data? {
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.setTextDrawingMode(.invisible)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for (text, rect) in invisibleText where rect.width > 0 && rect.height > 0 && !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height * 0.85), nil)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard natural > 0 else { continue }
            ctx.textMatrix = CGAffineTransform(scaleX: rect.width / CGFloat(natural), y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    /// Per-line text with bounds in page space (only meaningful for unrotated pages with crop box at origin).
    static func textLines(of page: PDFPage) -> [(String, CGRect)] {
        let bounds = page.bounds(for: .cropBox)
        guard page.rotation == 0, let selection = page.selection(for: bounds) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let s = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            let r = line.bounds(for: page)
            return (s, CGRect(x: r.minX - bounds.minX, y: r.minY - bounds.minY, width: r.width, height: r.height))
        }
    }
}

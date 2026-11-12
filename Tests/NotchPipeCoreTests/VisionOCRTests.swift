import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import NotchPipeCore

/// Renders black text on white with CoreText into a PNG.
func renderTextPNG(_ text: String, to url: URL, fontSize: CGFloat = 96, size: CGSize = CGSize(width: 1200, height: 260)) throws {
    let w = Int(size.width), h = Int(size.height)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw PipelineError.failed("no context")
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
    ctx.textPosition = CGPoint(x: 40, y: size.height / 2 - fontSize / 3)
    CTLineDraw(line, ctx)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw PipelineError.failed("no destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw PipelineError.failed("png write failed") }
}

@Test func ocrReadsRenderedText() async throws {
    let dir = try makeTempDir("ocr")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("text.png")
    try renderTextPNG("NotchPipe 2026", to: url)

    let text = try await VisionOCRService().recognizeText(in: url)
    let normalized = text.lowercased().replacingOccurrences(of: " ", with: "")
    #expect(normalized.contains("notchpipe"), "OCR output was: \(text)")
    #expect(text.contains("2026"), "OCR output was: \(text)")
}

@Test func ocrRejectsNonImages() async throws {
    let dir = try makeTempDir("ocr")
    defer { try? FileManager.default.removeItem(at: dir) }
    let txt = try writeFile(dir, "a.txt", bytes: 10)
    let pdf = try writeFile(dir, "a.pdf", bytes: 10)
    for url in [txt, pdf] {
        do {
            _ = try await VisionOCRService().recognizeText(in: url)
            Issue.record("should throw for \(url.lastPathComponent)")
        } catch let e as PipelineError {
            guard case .unsupportedInput = e else { Issue.record("wrong error \(e)"); continue }
        }
    }
}

@Test func ocrFailsCleanlyOnMissingOrCorruptImage() async throws {
    let dir = try makeTempDir("ocr")
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        _ = try await VisionOCRService().recognizeText(in: dir.appendingPathComponent("nope.png"))
        Issue.record("should throw")
    } catch let e as PipelineError {
        guard case .failed = e else { Issue.record("wrong error \(e)"); return }
    }
    let corrupt = try writeFile(dir, "corrupt.png", bytes: 64)
    do {
        _ = try await VisionOCRService().recognizeText(in: corrupt)
        Issue.record("should throw")
    } catch let e as PipelineError {
        guard case .failed = e else { Issue.record("wrong error \(e)"); return }
    }
}

@Test func chainerOCRUsesRealVisionService() async throws {
    let root = try makeTempDir("ocr-root")
    let dir = try makeTempDir("ocr")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("text.png")
    try renderTextPNG("NotchPipe 2026", to: url)
    let chainer = PipelineChainer(storage: StashStorageService(rootURL: root))
    let output = try await chainer.run(.single(.ocrToClipboard), on: [StashedItem(url: url)])
    guard case .text(let text) = output else { Issue.record("expected text"); return }
    #expect(text.contains("2026"), "OCR output was: \(text)")
}

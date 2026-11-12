import Foundation
import CoreGraphics
import PDFKit

/// Synchronous PDF implementations; PDFPipelineService runs them off the main thread.
enum PDFWork {

    static func merge(_ inputs: [URL], into directory: URL) throws -> URL {
        guard inputs.count >= 2 else { throw PipelineError.notEnoughInputs(needed: 2, got: inputs.count) }
        let merged = PDFDocument()
        var sources: [PDFDocument] = []      // keep source documents alive until the write is done
        var index = 0
        for url in inputs {
            try MediaSupport.checkCancelled()
            let doc = try PDFSupport.load(url)
            sources.append(doc)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let copy = page.copy() as? PDFPage else { continue }
                merged.insert(copy, at: index)
                index += 1
            }
        }
        guard index > 0 else { throw PipelineError.unsupportedInput("none of the PDFs contain pages") }
        try MediaSupport.checkCancelled()
        let out = try MediaSupport.reserveOutput(baseName: "Merged", ext: "pdf", in: directory)
        guard merged.write(to: out) else {
            MediaSupport.discard(out)
            throw PipelineError.failed("Could not write merged PDF")
        }
        withExtendedLifetime(sources) {}
        return out
    }

    static func compress(_ input: URL, into directory: URL) throws -> URL {
        let src = try PDFSupport.load(input)
        guard let cgDoc = src.documentRef else { throw PipelineError.unsupportedInput("cannot read PDF structure") }
        let result = PDFDocument()
        var rasterised: [PDFDocument] = []

        let targetDPI: CGFloat = 150
        for i in 0..<src.pageCount {
            try MediaSupport.checkCancelled()
            guard let page = src.page(at: i), let copy = page.copy() as? PDFPage else { continue }
            var replacement: PDFPage?

            if let cgPage = cgDoc.page(at: i + 1) {
                let images = PDFSupport.embeddedImages(of: cgPage)
                let size = PDFSupport.displaySize(of: cgPage)
                let widthInches = max(size.width, 1) / 72
                // Effective resolution if the widest image spanned the page width (true for scans).
                let heaviest = images.max { $0.width < $1.width }
                let imageBytes = images.reduce(0) { $0 + $1.byteLength }
                if let heaviest, imageBytes > 60_000, CGFloat(heaviest.width) / widthInches > targetDPI * 1.15,
                   let image = PDFSupport.render(cgPage, scale: targetDPI / 72),
                   let jpeg = PDFSupport.jpegData(image, quality: 0.55),
                   jpeg.count < imageBytes,
                   let pdfData = PDFSupport.singleImagePagePDF(jpeg: jpeg, size: size, invisibleText: PDFSupport.textLines(of: page)),
                   let onePage = PDFDocument(data: pdfData), let newPage = onePage.page(at: 0) {
                    rasterised.append(onePage)
                    replacement = newPage.copy() as? PDFPage
                }
            }
            result.insert(replacement ?? copy, at: result.pageCount)
        }
        try MediaSupport.checkCancelled()
        let out = try MediaSupport.reserveOutput(forInput: input, suffix: "-compressed", ext: "pdf", in: directory)
        guard result.write(to: out) else {
            MediaSupport.discard(out)
            throw PipelineError.failed("Could not write compressed PDF")
        }
        withExtendedLifetime(rasterised) {}
        return out
    }

    static func extractText(_ input: URL, into directory: URL) throws -> URL {
        let doc = try PDFSupport.load(input)
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try MediaSupport.checkCancelled()
            pages.append((doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard pages.contains(where: { !$0.isEmpty }) else {
            throw PipelineError.failed("No extractable text in \(input.lastPathComponent) — it looks like a scan; run OCR on its images instead")
        }
        let text = pages.joined(separator: "\n\n\u{0C}\n\n")
        let out = try MediaSupport.reserveOutput(forInput: input, ext: "txt", in: directory)
        try MediaSupport.write(Data(text.utf8), to: out)
        return out
    }

    static func extractImages(_ input: URL, into directory: URL) throws -> [URL] {
        let doc = try PDFSupport.load(input)
        guard let cgDoc = doc.documentRef else { throw PipelineError.unsupportedInput("cannot read PDF structure") }
        var outputs: [URL] = []
        do {
            for n in 1...max(1, cgDoc.numberOfPages) {
                try MediaSupport.checkCancelled()
                guard let page = cgDoc.page(at: n),
                      let image = PDFSupport.render(page, scale: 2),
                      let png = PDFSupport.pngData(image) else {
                    throw PipelineError.failed("Could not render page \(n)")
                }
                let out = try MediaSupport.reserveOutput(forInput: input, suffix: "-p\(n)", ext: "png", in: directory)
                outputs.append(out)
                try MediaSupport.write(png, to: out)
            }
        } catch {
            outputs.forEach(MediaSupport.discard)
            throw error
        }
        return outputs
    }
}

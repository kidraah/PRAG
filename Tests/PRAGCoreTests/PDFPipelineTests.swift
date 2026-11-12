import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import PRAGCore

@Suite("PDF pipeline")
struct PDFPipelineTests {
    let service = PDFPipelineService()

    private func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? -1 }

    @Test func mergeConcatenatesPagesInOrder() async throws {
        try await MediaFixtures.withTempDir { dir in
            let a = try MediaFixtures.makePDF(in: dir, name: "a.pdf", pageTexts: ["Alpha one", "Alpha two"])
            let b = try MediaFixtures.makePDF(in: dir, name: "b.pdf", pageTexts: ["Bravo one", "Bravo two", "Bravo three"])
            let beforeA = try MediaFixtures.bytes(a), beforeB = try MediaFixtures.bytes(b)
            let outDir = dir.appendingPathComponent("out")
            let out = try await service.merge([a, b], into: outDir)

            #expect(out.lastPathComponent == "Merged.pdf")
            #expect(pageCount(out) == 5)
            let doc = PDFDocument(url: out)!
            #expect(doc.page(at: 0)?.string?.contains("Alpha one") == true)
            #expect(doc.page(at: 2)?.string?.contains("Bravo one") == true)
            #expect(doc.page(at: 4)?.string?.contains("Bravo three") == true)
            #expect(try MediaFixtures.bytes(a) == beforeA)
            #expect(try MediaFixtures.bytes(b) == beforeB)

            let again = try await service.merge([b, a], into: outDir)
            #expect(again.lastPathComponent == "Merged-1.pdf")
        }
    }

    @Test func mergeNeedsTwoInputs() async throws {
        try await MediaFixtures.withTempDir { dir in
            let a = try MediaFixtures.makePDF(in: dir, name: "a.pdf", pageTexts: ["x"])
            await #expect(throws: PipelineError.notEnoughInputs(needed: 2, got: 1)) {
                _ = try await service.merge([a], into: dir.appendingPathComponent("o"))
            }
        }
    }

    @Test func compressShrinksScannedPDF() async throws {
        try await MediaFixtures.withTempDir { dir in
            let scan = try MediaFixtures.makeScanPDF(in: dir, pages: 2)
            let before = try MediaFixtures.bytes(scan)
            let out = try await service.compress(scan, into: dir.appendingPathComponent("o"))
            #expect(out.lastPathComponent == "scan-compressed.pdf")
            #expect(pageCount(out) == 2)
            #expect(MediaFixtures.fileSize(out) < MediaFixtures.fileSize(scan) / 2)
            // page geometry preserved
            let size = PDFDocument(url: out)!.page(at: 0)!.bounds(for: .mediaBox).size
            #expect(abs(size.width - 595) < 1 && abs(size.height - 842) < 1)
            #expect(try MediaFixtures.bytes(scan) == before)
        }
    }

    @Test func compressKeepsTextPDFsVector() async throws {
        try await MediaFixtures.withTempDir { dir in
            let pdf = try MediaFixtures.makePDF(in: dir, name: "text.pdf", pageTexts: ["Vector text survives", "Second page"])
            let out = try await service.compress(pdf, into: dir.appendingPathComponent("o"))
            let doc = PDFDocument(url: out)!
            #expect(doc.pageCount == 2)
            #expect(doc.page(at: 0)?.string?.contains("Vector text survives") == true)
        }
    }

    @Test func extractTextContainsDrawnText() async throws {
        try await MediaFixtures.withTempDir { dir in
            let pdf = try MediaFixtures.makePDF(in: dir, name: "doc.pdf", pageTexts: ["Hello PRAG", "Goodbye pages"])
            let before = try MediaFixtures.bytes(pdf)
            let out = try await service.extractText(pdf, into: dir.appendingPathComponent("o"))
            #expect(out.lastPathComponent == "doc.txt")
            let text = try String(contentsOf: out, encoding: .utf8)
            #expect(text.contains("Hello PRAG"))
            #expect(text.contains("Goodbye pages"))
            #expect(text.firstRange(of: "Hello")!.lowerBound < text.firstRange(of: "Goodbye")!.lowerBound)
            #expect(try MediaFixtures.bytes(pdf) == before)
        }
    }

    @Test func extractTextFromScanThrowsHelpfulError() async throws {
        try await MediaFixtures.withTempDir { dir in
            let scan = try MediaFixtures.makeScanPDF(in: dir, pages: 1)
            await #expect(throws: PipelineError.self) {
                _ = try await service.extractText(scan, into: dir.appendingPathComponent("o"))
            }
        }
    }

    @Test func extractImagesRendersEveryPageAt2x() async throws {
        try await MediaFixtures.withTempDir { dir in
            let pdf = try MediaFixtures.makePDF(in: dir, name: "pages.pdf", pageTexts: ["One", "Two", "Three"])
            let outs = try await service.extractImages(pdf, into: dir.appendingPathComponent("o"))
            #expect(outs.map(\.lastPathComponent) == ["pages-p1.png", "pages-p2.png", "pages-p3.png"])
            for url in outs {
                #expect(MediaFixtures.utType(of: url) == "public.png")
                #expect(MediaFixtures.pixelSize(of: url)?.w == 1224)
                #expect(MediaFixtures.pixelSize(of: url)?.h == 1584)
            }
        }
    }

    @Test func notAPDFIsRejected() async throws {
        try await MediaFixtures.withTempDir { dir in
            let bad = dir.appendingPathComponent("bad.pdf")
            try Data("nope".utf8).write(to: bad)
            await #expect(throws: PipelineError.self) { _ = try await service.compress(bad, into: dir.appendingPathComponent("o")) }
        }
    }
}

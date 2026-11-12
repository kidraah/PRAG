import Testing
import Foundation
@testable import PRAGCore

// MARK: - Fakes

/// Fake media backends: every op writes a deterministic file into the given directory.
/// Output size = input size × `factor` (min 1 byte). Merge/zip sum their inputs.
struct FakeBackend: ImageOps, PDFOps, VideoOps, OCROps, ArchiveOps {
    var log = CallLog()
    var factor: Double = 0.5
    /// Called before each op ("op:file"); throw to simulate failures, sleep to simulate work.
    var hook: @Sendable (String) async throws -> Void = { _ in }
    var ocrText: @Sendable (URL) -> String = { "text(\($0.lastPathComponent))" }
    var pdfImageCount = 3
    var videoProgressSteps = [0.25, 0.5, 0.75, 1.0]

    private func produce(_ op: String, from input: URL, into dir: URL, ext: String? = nil, name: String? = nil) async throws -> URL {
        log.add("\(op):\(input.lastPathComponent)")
        try await hook("\(op):\(input.lastPathComponent)")
        let base = input.deletingPathExtension().lastPathComponent
        let out = dir.appendingPathComponent(name ?? (base + "." + (ext ?? input.pathExtension)))
        let size = max(1, Int(Double(fileBytes(input)) * factor))
        try Data(repeating: 0x42, count: size).write(to: out)
        return out
    }

    // ImageOps
    func stripMetadata(_ input: URL, into directory: URL) async throws -> URL {
        try await produce("strip", from: input, into: directory)
    }
    func compress(_ input: URL, quality: Double, into directory: URL) async throws -> URL {
        try await produce("compressImage", from: input, into: directory)
    }
    func convert(_ input: URL, to format: ImageFormat, quality: Double, into directory: URL) async throws -> URL {
        try await produce("convert(\(format.rawValue),q=\(quality))", from: input, into: directory, ext: format.fileExtension)
    }
    func resize(_ input: URL, maxDimension: Int, into directory: URL) async throws -> URL {
        try await produce("resize(\(maxDimension))", from: input, into: directory)
    }

    // PDFOps
    func merge(_ inputs: [URL], into directory: URL) async throws -> URL {
        log.add("merge:" + inputs.map(\.lastPathComponent).joined(separator: ","))
        try await hook("merge")
        let out = directory.appendingPathComponent("Merged.pdf")
        let total = inputs.reduce(Int64(0)) { $0 + fileBytes($1) }
        try Data(repeating: 0x43, count: Int(total)).write(to: out)
        return out
    }
    func compress(_ input: URL, into directory: URL) async throws -> URL {
        try await produce("compressPDF", from: input, into: directory)
    }
    func extractText(_ input: URL, into directory: URL) async throws -> URL {
        try await produce("extractText", from: input, into: directory, ext: "txt")
    }
    func extractImages(_ input: URL, into directory: URL) async throws -> [URL] {
        log.add("extractImages:\(input.lastPathComponent)")
        try await hook("extractImages:\(input.lastPathComponent)")
        var urls: [URL] = []
        for i in 1...pdfImageCount {
            let u = directory.appendingPathComponent("page-\(i).png")
            try Data(repeating: 0x44, count: 100).write(to: u)
            urls.append(u)
        }
        return urls
    }

    // VideoOps
    func compress(_ input: URL, preset: VideoPreset, into directory: URL, progress: ProgressHandler?) async throws -> URL {
        for p in videoProgressSteps { progress?(p) }
        return try await produce("compressVideo(\(preset.rawValue))", from: input, into: directory)
    }
    func extractAudio(_ input: URL, into directory: URL, progress: ProgressHandler?) async throws -> URL {
        try await produce("extractAudio", from: input, into: directory, ext: "m4a")
    }
    func toGIF(_ input: URL, into directory: URL, maxWidth: Int, fps: Double, progress: ProgressHandler?) async throws -> URL {
        try await produce("gif", from: input, into: directory, ext: "gif")
    }

    // OCROps
    func recognizeText(in imageURL: URL) async throws -> String {
        log.add("ocr:\(imageURL.lastPathComponent)")
        try await hook("ocr:\(imageURL.lastPathComponent)")
        return ocrText(imageURL)
    }

    // ArchiveOps
    func zip(_ inputs: [URL], into directory: URL) async throws -> URL {
        log.add("zip:" + inputs.map(\.lastPathComponent).joined(separator: ","))
        try await hook("zip")
        let out = directory.appendingPathComponent(inputs.count == 1 ? inputs[0].lastPathComponent + ".zip" : "Archive.zip")
        let total = inputs.reduce(Int64(0)) { $0 + fileBytes($1) }
        try Data(repeating: 0x45, count: max(1, Int(Double(total) * 0.9))).write(to: out)
        return out
    }
}

struct Harness {
    let root: URL
    let inputs: URL
    let storage: StashStorageService
    let fake: FakeBackend
    let chainer: PipelineChainer

    init(fake: FakeBackend = FakeBackend()) throws {
        root = try makeTempDir("chain-root")
        inputs = try makeTempDir("chain-in")
        storage = StashStorageService(rootURL: root)
        self.fake = fake
        chainer = PipelineChainer(storage: storage,
                                  backends: ChainerBackends(images: fake, pdfs: fake, videos: fake, ocr: fake, archive: fake))
    }

    func input(_ name: String, bytes: Int) throws -> StashedItem {
        StashedItem(url: try writeFile(inputs, name, bytes: bytes))
    }

    /// Step directories currently present in the workspace.
    var workspaceDirs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: storage.workspaceURL.path)) ?? []).sorted()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: inputs)
    }
}

// MARK: - Tests

@Test func chainerPerFileStepsRunInOrderAndMapOneToOne() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let a = try h.input("a.png", bytes: 1000)
    let b = try h.input("b.png", bytes: 3000)
    let pipeline = ActionPipeline(name: "t", symbol: "x", steps: [.compressImage(quality: 0.7), .convertImage(.webp)])

    let output = try await h.chainer.run(pipeline, on: [a, b])
    guard case .items(let items) = output else { Issue.record("expected items"); return }

    #expect(items.count == 2)
    #expect(items.map(\.displayName) == ["a.webp", "b.webp"])          // input order preserved, name = file name
    #expect(items.map(\.origin) == [.processed, .processed])
    #expect(items.allSatisfy { $0.appliedSteps == pipeline.steps })
    #expect(items.map(\.sourceURL) == [a.url, b.url])
    // 1000 → 500 → 250 and 3000 → 1500 → 750
    #expect(items[0].delta == ByteDelta(before: 1000, after: 250))
    #expect(items[1].delta == ByteDelta(before: 3000, after: 750))
    #expect(items.map(\.byteSize) == [250, 750])
    #expect(items[0].kind == .image)

    // Whole step 1 for every file runs before step 2 starts; convert uses quality 0.82.
    #expect(h.fake.log.entries == [
        "compressImage:a.png", "compressImage:b.png",
        "convert(webp,q=0.82):a.png", "convert(webp,q=0.82):b.png",
    ])
    // Intermediates deleted: only the two final directories remain, and they hold the outputs.
    #expect(h.workspaceDirs.count == 2)
    for item in items { #expect(h.storage.isWorkspaceURL(item.url)); #expect(FileManager.default.fileExists(atPath: item.url.path)) }
    // Originals untouched.
    #expect(fileBytes(a.url) == 1000)
    #expect(fileBytes(b.url) == 3000)
}

@Test func chainerSameNamedInputsDoNotCollide() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let other = try makeTempDir("chain-in2")
    defer { try? FileManager.default.removeItem(at: other) }
    let a = try h.input("shot.png", bytes: 100)
    let b = StashedItem(url: try writeFile(other, "shot.png", bytes: 200))
    guard case .items(let items) = try await h.chainer.run(.single(.stripMetadata), on: [a, b]) else { Issue.record("items"); return }
    #expect(items.count == 2)
    #expect(items[0].url != items[1].url)
    #expect(items.map(\.byteSize) == [50, 100])
}

@Test func chainerAggregationCollapsesNToOne() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let items = [try h.input("1.pdf", bytes: 400), try h.input("2.pdf", bytes: 600), try h.input("3.pdf", bytes: 1000)]
    guard case .items(let out) = try await h.chainer.run(ActionPipeline.submissionReady, on: items) else { Issue.record("items"); return }

    #expect(out.count == 1)
    #expect(out[0].displayName == "Merged.pdf")
    #expect(out[0].sourceURL == items[0].url)                          // first input
    #expect(out[0].delta == ByteDelta(before: 2000, after: 1000))      // merge keeps 2000, compress halves
    #expect(h.fake.log.entries.first == "merge:1.pdf,2.pdf,3.pdf")
    #expect(h.fake.log.entries.last == "compressPDF:Merged.pdf")
    #expect(h.workspaceDirs.count == 1)
}

@Test func chainerZipAggregatesAnyKind() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let items = [try h.input("a.png", bytes: 1000), try h.input("b.pdf", bytes: 1000)]
    guard case .items(let out) = try await h.chainer.run(.single(.zip), on: items) else { Issue.record("items"); return }
    #expect(out.count == 1)
    #expect(out[0].displayName == "Archive.zip")
    #expect(out[0].delta == ByteDelta(before: 2000, after: 1800))
}

@Test func chainerPerFileThenZip() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let items = [try h.input("a.png", bytes: 1000), try h.input("b.png", bytes: 1000)]
    let pipeline = ActionPipeline(name: "t", symbol: "x", steps: [.stripMetadata, .zip])
    guard case .items(let out) = try await h.chainer.run(pipeline, on: items) else { Issue.record("items"); return }
    #expect(out.count == 1)
    #expect(out[0].delta == ByteDelta(before: 2000, after: 900))       // 2 × 500 zipped at 0.9
    #expect(out[0].sourceURL == items[0].url)
    #expect(h.workspaceDirs.count == 1)
}

@Test func chainerOneToManyExtractionSharesGroupDelta() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let pdf = try h.input("doc.pdf", bytes: 5000)
    guard case .items(let out) = try await h.chainer.run(.single(.extractPDFImages), on: [pdf]) else { Issue.record("items"); return }
    #expect(out.count == 3)
    #expect(out.map(\.displayName) == ["page-1.png", "page-2.png", "page-3.png"])
    #expect(out.allSatisfy { $0.delta == ByteDelta(before: 5000, after: 300) })
    #expect(out.allSatisfy { $0.sourceURL == pdf.url && $0.kind == .image })
    #expect(h.workspaceDirs.count == 1)   // the three pages share one step dir
}

@Test func chainerVideoStepsMapToServices() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let v = try h.input("clip.mov", bytes: 8000)
    guard case .items(let out) = try await h.chainer.run(.single(.compressVideo(.p720)), on: [v]) else { Issue.record("items"); return }
    #expect(out[0].displayName == "clip.mov")
    #expect(h.fake.log.entries == ["compressVideo(p720):clip.mov"])
    guard case .items(let audio) = try await h.chainer.run(.single(.extractAudio), on: [v]) else { Issue.record("items"); return }
    #expect(audio[0].displayName == "clip.m4a")
    guard case .items(let gif) = try await h.chainer.run(.single(.videoToGIF), on: [v]) else { Issue.record("items"); return }
    #expect(gif[0].displayName == "clip.gif")
}

@Test func chainerOCRIsTerminalAndJoinsTexts() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let a = try h.input("a.png", bytes: 100)
    let b = try h.input("b.png", bytes: 100)
    let pipeline = ActionPipeline(name: "t", symbol: "x", steps: [.stripMetadata, .ocrToClipboard])
    let output = try await h.chainer.run(pipeline, on: [a, b])
    guard case .text(let text) = output else { Issue.record("expected text"); return }
    #expect(text == "text(a.png)\n\ntext(b.png)")
    #expect(h.workspaceDirs.isEmpty)                                    // text result leaves no files behind
}

@Test func chainerValidation() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let png = try h.input("a.png", bytes: 10)
    let pdf = try h.input("a.pdf", bytes: 10)

    await #expect(throws: PipelineError.notEnoughInputs(needed: 2, got: 1)) {
        _ = try await h.chainer.run(.single(.mergePDFs), on: [pdf])
    }
    await #expect(throws: PipelineError.unsupportedInput("a.pdf (pdf) can't be used with Compress")) {
        _ = try await h.chainer.run(.single(.compressImage(quality: 0.5)), on: [pdf])
    }
    let badOrder = ActionPipeline(name: "bad", symbol: "x", steps: [.ocrToClipboard, .stripMetadata])
    await #expect(throws: (any Error).self) { _ = try await h.chainer.run(badOrder, on: [png]) }
    do {
        _ = try await h.chainer.run(badOrder, on: [png])
        Issue.record("should throw")
    } catch let e as PipelineError {
        guard case .invalidChain = e else { Issue.record("wrong error \(e)"); return }
    }
    do {
        _ = try await h.chainer.run(ActionPipeline(name: "e", symbol: "x", steps: []), on: [png])
        Issue.record("should throw")
    } catch let e as PipelineError {
        guard case .invalidChain = e else { Issue.record("wrong error \(e)"); return }
    }
    #expect(h.workspaceDirs.isEmpty)
    #expect(h.fake.log.entries.isEmpty)
}

@Test func chainerCleansUpWorkspaceOnFailure() async throws {
    var fake = FakeBackend()
    fake.hook = { op in if op == "convert(webp,q=0.82):b.png" { throw PipelineError.failed("boom") } }
    let h = try Harness(fake: fake)
    defer { h.cleanup() }
    let a = try h.input("a.png", bytes: 100)
    let b = try h.input("b.png", bytes: 100)
    let pipeline = ActionPipeline(name: "t", symbol: "x", steps: [.compressImage(quality: 0.5), .convertImage(.webp)])
    do {
        _ = try await h.chainer.run(pipeline, on: [a, b])
        Issue.record("should throw")
    } catch let e as PipelineError {
        #expect(e == .failed("boom"))
    }
    #expect(h.workspaceDirs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: a.url.path))
}

@Test func chainerForeignErrorsBecomeFailed() async throws {
    struct Weird: Error, LocalizedError { var errorDescription: String? { "weird" } }
    var fake = FakeBackend()
    fake.hook = { _ in throw Weird() }
    let h = try Harness(fake: fake)
    defer { h.cleanup() }
    let a = try h.input("a.png", bytes: 100)
    do {
        _ = try await h.chainer.run(.single(.stripMetadata), on: [a])
        Issue.record("should throw")
    } catch let e as PipelineError {
        #expect(e == .failed("weird"))
    }
}

@Test func chainerHonorsCancellationAndCleansUp() async throws {
    var fake = FakeBackend()
    fake.hook = { op in
        if op.hasPrefix("compressImage:b.png") { try await Task.sleep(nanoseconds: 30_000_000_000) }
    }
    let h = try Harness(fake: fake)
    defer { h.cleanup() }
    let items = [try h.input("a.png", bytes: 100), try h.input("b.png", bytes: 100), try h.input("c.png", bytes: 100)]
    let chainer = h.chainer
    let task = Task { try await chainer.run(.single(.compressImage(quality: 0.5)), on: items) }
    #expect(await waitUntil { h.fake.log.entries.contains("compressImage:b.png") })
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("should throw")
    } catch let e as PipelineError {
        #expect(e == .cancelled)
    }
    #expect(h.workspaceDirs.isEmpty)
    #expect(!h.fake.log.entries.contains("compressImage:c.png"))        // stopped before the third file
}

@Test func chainerCancelledBeforeStart() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let a = try h.input("a.png", bytes: 100)
    let chainer = h.chainer
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await chainer.run(.single(.stripMetadata), on: [a])
    }
    do { _ = try await task.value; Issue.record("should throw") }
    catch let e as PipelineError { #expect(e == .cancelled) }
    #expect(h.workspaceDirs.isEmpty)
}

@Test func chainerProgressIsMonotonicFromZeroToOne() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let items = [try h.input("a.mov", bytes: 1000), try h.input("b.mov", bytes: 1000)]
    let values = Collector<Double>()
    let pipeline = ActionPipeline(name: "t", symbol: "x", steps: [.compressVideo(.p720), .extractAudio, .zip])
    _ = try await h.chainer.run(pipeline, on: items) { values.add($0) }
    let v = values.values
    #expect(v.first == 0)
    #expect(v.last == 1)
    #expect(zip(v, v.dropFirst()).allSatisfy { $0 < $1 })               // strictly increasing, never regresses
    #expect(v.allSatisfy { (0...1).contains($0) })
    #expect(v.count > 4)                                                // intermediate updates happened
}

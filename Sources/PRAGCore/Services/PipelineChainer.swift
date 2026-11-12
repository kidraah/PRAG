import Foundation

public enum PipelineOutput: Sendable {
    case items([StashedItem])   // new processed items to add to the shelf
    case text(String)           // e.g. OCR result for the clipboard
}

// MARK: - Internal service seams
//
// The chainer talks to the media/OCR/archive services through these small protocols so the chaining
// logic (ordering, N→1 aggregation, per-file mapping, delta math, cancellation, progress) can be unit
// tested with fakes. The real services conform below with no extra code.

protocol ImageOps: Sendable {
    func stripMetadata(_ input: URL, into directory: URL) async throws -> URL
    func compress(_ input: URL, quality: Double, into directory: URL) async throws -> URL
    func convert(_ input: URL, to format: ImageFormat, quality: Double, into directory: URL) async throws -> URL
    func resize(_ input: URL, maxDimension: Int, into directory: URL) async throws -> URL
}

protocol PDFOps: Sendable {
    func merge(_ inputs: [URL], into directory: URL) async throws -> URL
    func compress(_ input: URL, into directory: URL) async throws -> URL
    func extractText(_ input: URL, into directory: URL) async throws -> URL
    func extractImages(_ input: URL, into directory: URL) async throws -> [URL]
}

protocol VideoOps: Sendable {
    func compress(_ input: URL, preset: VideoPreset, into directory: URL, progress: ProgressHandler?) async throws -> URL
    func extractAudio(_ input: URL, into directory: URL, progress: ProgressHandler?) async throws -> URL
    func toGIF(_ input: URL, into directory: URL, maxWidth: Int, fps: Double, progress: ProgressHandler?) async throws -> URL
}

protocol OCROps: Sendable {
    func recognizeText(in imageURL: URL) async throws -> String
}

protocol ArchiveOps: Sendable {
    func zip(_ inputs: [URL], into directory: URL) async throws -> URL
}

extension ImagePipelineService: ImageOps {}
extension PDFPipelineService: PDFOps {}
extension VideoPipelineService: VideoOps {}
extension VisionOCRService: OCROps {}
extension ArchiveService: ArchiveOps {}

struct ChainerBackends: Sendable {
    var images: any ImageOps
    var pdfs: any PDFOps
    var videos: any VideoOps
    var ocr: any OCROps
    var archive: any ArchiveOps
}

// MARK: - Chainer

// Public API contract — the app target depends on these signatures.
// Runs each step in order. Per-file steps map over all current files; aggregating steps (merge, zip)
// collapse them into one. Intermediate files go into fresh step dirs; final outputs become
// StashedItems with origin .processed, appliedSteps = pipeline.steps, sourceURL = first input,
// and delta = ByteDelta(before: sum of input sizes, after: sum of output sizes)
// (for 1:1 runs, one output item per input with its own delta).
// Honors Task cancellation (throw PipelineError.cancelled) and reports overall progress 0...1.
//
// Implementation notes:
// • Per-file steps get one step directory per input file, so same-named inputs never collide and a
//   final item owns its directory (discarding it removes the directory).
// • Lineage is tracked per file: each current file knows which original inputs it derives from. A final
//   group (all outputs with the same set of originals) gets delta = (sum of those originals' sizes →
//   sum of that group's outputs) and sourceURL = the first original of the group. For 1:1 runs that is
//   exactly "one item per input with its own delta"; a 1→N step (extract PDF images) gives every
//   extracted image the same group delta.
// • Intermediate step directories are deleted once the chain succeeds; everything this run created is
//   deleted on error or cancellation.
// • Progress is monotonic: it only ever moves forward, starts at 0 and finishes at exactly 1.
public actor PipelineChainer {
    private let storage: StashStorageService
    private let backends: ChainerBackends

    public init(storage: StashStorageService,
                images: ImagePipelineService = .init(),
                pdfs: PDFPipelineService = .init(),
                videos: VideoPipelineService = .init(),
                ocr: VisionOCRService = .init(),
                archive: ArchiveService = .init()) {
        self.storage = storage
        self.backends = ChainerBackends(images: images, pdfs: pdfs, videos: videos, ocr: ocr, archive: archive)
    }

    /// Test seam: inject fake services.
    init(storage: StashStorageService, backends: ChainerBackends) {
        self.storage = storage
        self.backends = backends
    }

    /// A file flowing through the chain plus the indices of the original inputs it derives from.
    private struct Work {
        var url: URL
        var origins: [Int]
    }

    public func run(_ pipeline: ActionPipeline, on items: [StashedItem], progress: ProgressHandler? = nil) async throws -> PipelineOutput {
        // ── Validation ──
        guard pipeline.isValidChain, let first = pipeline.steps.first else {
            throw PipelineError.invalidChain(pipeline.steps.isEmpty
                ? "pipeline has no steps"
                : "steps do not fit together: \(pipeline.breadcrumb)")
        }
        guard items.count >= first.minimumInputs else {
            throw PipelineError.notEnoughInputs(needed: first.minimumInputs, got: items.count)
        }
        for item in items where !first.acceptedKinds.contains(item.kind) {
            throw PipelineError.unsupportedInput("\(item.displayName) (\(item.kind.rawValue)) can't be used with \(first.title)")
        }
        if Task.isCancelled { throw PipelineError.cancelled }

        let meter = ProgressMeter(progress)
        meter.report(0)

        let inputSizes: [Int64] = items.map {
            let actual = StashedItem.fileSize(at: $0.url)
            return actual > 0 ? actual : $0.byteSize
        }

        var createdDirs: [URL] = []
        do {
            var current = items.enumerated().map { Work(url: $1.url, origins: [$0]) }
            var terminalText: String?
            let stepCount = pipeline.steps.count

            for (stepIndex, step) in pipeline.steps.enumerated() {
                try checkCancelled()
                guard current.count >= step.minimumInputs else {
                    throw PipelineError.notEnoughInputs(needed: step.minimumInputs, got: current.count)
                }
                let base = Double(stepIndex) / Double(stepCount)
                let span = 1.0 / Double(stepCount)

                if step.isTerminalText {
                    var texts: [String] = []
                    for (i, work) in current.enumerated() {
                        try checkCancelled()
                        texts.append(try await translate { try await self.backends.ocr.recognizeText(in: work.url) })
                        meter.report(base + span * Double(i + 1) / Double(current.count))
                    }
                    terminalText = texts.joined(separator: "\n\n")
                    current = []
                } else if step.isAggregating {
                    let dir = try await newStepDirectory(&createdDirs)
                    let urls = current.map(\.url)
                    let out: URL = try await translate {
                        switch step {
                        case .mergePDFs: return try await self.backends.pdfs.merge(urls, into: dir)
                        case .zip: return try await self.backends.archive.zip(urls, into: dir)
                        default: throw PipelineError.invalidChain("\(step.title) is not an aggregating step")
                        }
                    }
                    let origins = Array(Set(current.flatMap(\.origins))).sorted()
                    current = [Work(url: out, origins: origins)]
                    meter.report(base + span)
                } else {
                    var next: [Work] = []
                    let total = current.count
                    for (i, work) in current.enumerated() {
                        try checkCancelled()
                        let dir = try await newStepDirectory(&createdDirs)
                        // Video steps report fractional progress for the file they are working on.
                        let fileProgress: ProgressHandler = { p in
                            let clamped = min(max(p, 0), 1)
                            meter.report(base + span * (Double(i) + clamped) / Double(total))
                        }
                        let outs = try await translate { try await self.perFile(step, work.url, dir, fileProgress) }
                        next += outs.map { Work(url: $0, origins: work.origins) }
                        meter.report(base + span * Double(i + 1) / Double(total))
                    }
                    current = next
                }
            }

            try checkCancelled()

            // ── Result ──
            if let text = terminalText {
                await removeDirectories(createdDirs)
                meter.report(1)
                return .text(text)
            }

            let finalItems = makeItems(from: current, pipeline: pipeline, originals: items, inputSizes: inputSizes)

            // Keep only directories that hold a final output; drop all intermediates.
            let finalPaths = current.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path }
            var intermediates: [URL] = []
            for dir in createdDirs {
                let prefix = dir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                if !finalPaths.contains(where: { $0.hasPrefix(prefix) }) { intermediates.append(dir) }
            }
            await removeDirectories(intermediates)
            meter.report(1)
            return .items(finalItems)
        } catch {
            await removeDirectories(createdDirs)
            if error is CancellationError || Task.isCancelled { throw PipelineError.cancelled }
            throw error
        }
    }

    // MARK: Step execution

    private func perFile(_ step: ActionStep, _ url: URL, _ dir: URL, _ progress: @escaping ProgressHandler) async throws -> [URL] {
        switch step {
        case .stripMetadata:
            return [try await backends.images.stripMetadata(url, into: dir)]
        case .compressImage(let quality):
            return [try await backends.images.compress(url, quality: quality, into: dir)]
        case .convertImage(let format):
            return [try await backends.images.convert(url, to: format, quality: 0.82, into: dir)]
        case .resizeImage(let maxDimension):
            return [try await backends.images.resize(url, maxDimension: maxDimension, into: dir)]
        case .compressPDF:
            return [try await backends.pdfs.compress(url, into: dir)]
        case .extractPDFText:
            return [try await backends.pdfs.extractText(url, into: dir)]
        case .extractPDFImages:
            return try await backends.pdfs.extractImages(url, into: dir)
        case .compressVideo(let preset):
            return [try await backends.videos.compress(url, preset: preset, into: dir, progress: progress)]
        case .extractAudio:
            return [try await backends.videos.extractAudio(url, into: dir, progress: progress)]
        case .videoToGIF:
            return [try await backends.videos.toGIF(url, into: dir, maxWidth: 640, fps: 12, progress: progress)]
        case .mergePDFs, .zip, .ocrToClipboard:
            throw PipelineError.invalidChain("\(step.title) is not a per-file step")
        }
    }

    // MARK: Result building

    private func makeItems(from outputs: [Work], pipeline: ActionPipeline,
                           originals: [StashedItem], inputSizes: [Int64]) -> [StashedItem] {
        // Group outputs by the set of originals they derive from.
        let groupSums: [[Int]: Int64] = Dictionary(grouping: outputs, by: \.origins).mapValues { group in
            group.reduce(Int64(0)) { $0 + StashedItem.fileSize(at: $1.url) }
        }
        return outputs.map { work in
            let before = work.origins.reduce(Int64(0)) { $0 + inputSizes[$1] }
            let after = groupSums[work.origins] ?? StashedItem.fileSize(at: work.url)
            let source = originals[work.origins.first ?? 0].url
            return StashedItem(
                url: work.url,
                sourceURL: source,
                bookmark: storage.makeBookmark(for: work.url),
                displayName: work.url.lastPathComponent,
                origin: .processed,
                appliedSteps: pipeline.steps,
                delta: ByteDelta(before: before, after: after))
        }
    }

    // MARK: Helpers

    private func newStepDirectory(_ created: inout [URL]) async throws -> URL {
        let dir = try await storage.makeStepDirectory()
        created.append(dir)
        return dir
    }

    private func removeDirectories(_ dirs: [URL]) async {
        for dir in dirs { await storage.removeWorkspaceItem(at: dir) }
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw PipelineError.cancelled }
    }

    /// Normalises errors coming out of services: cancellation → `.cancelled`, foreign errors → `.failed`.
    private func translate<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as PipelineError {
            if Task.isCancelled, error != .cancelled { throw PipelineError.cancelled }
            throw error
        } catch is CancellationError {
            throw PipelineError.cancelled
        } catch {
            if Task.isCancelled { throw PipelineError.cancelled }
            throw PipelineError.failed(error.localizedDescription)
        }
    }
}

// MARK: - Progress

/// Thread-safe, forward-only progress reporter (video services call back from arbitrary threads).
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    private let handler: ProgressHandler?

    init(_ handler: ProgressHandler?) { self.handler = handler }

    func report(_ value: Double) {
        let v = min(max(value, 0), 1)
        lock.lock()
        defer { lock.unlock() }
        guard v > last else { return }
        last = v
        handler?(v)
    }
}

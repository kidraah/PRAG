import Foundation

public enum PipelineOutput: Sendable {
    case items([StashedItem])   // new processed items to add to the shelf
    case text(String)           // e.g. OCR result for the clipboard
}

// Public API contract — the app target depends on these signatures.
// Runs each step in order. Per-file steps map over all current files; aggregating steps (merge, zip)
// collapse them into one. Intermediate files go into fresh step dirs; final outputs become
// StashedItems with origin .processed, appliedSteps = pipeline.steps, sourceURL = first input,
// and delta = ByteDelta(before: sum of input sizes, after: sum of output sizes)
// (for 1:1 runs, one output item per input with its own delta).
// Honors Task cancellation (throw PipelineError.cancelled) and reports overall progress 0...1.
public actor PipelineChainer {
    public init(storage: StashStorageService,
                images: ImagePipelineService = .init(),
                pdfs: PDFPipelineService = .init(),
                videos: VideoPipelineService = .init(),
                ocr: VisionOCRService = .init(),
                archive: ArchiveService = .init()) {}

    public func run(_ pipeline: ActionPipeline, on items: [StashedItem], progress: ProgressHandler? = nil) async throws -> PipelineOutput {
        throw PipelineError.notImplemented("PipelineChainer.run")
    }
}

import Foundation
import Vision

// Public API contract — the app target depends on these signatures.
public struct VisionOCRService: Sendable {
    public init() {}

    /// Accurate-level text recognition with language correction. Lines joined by "\n".
    public func recognizeText(in imageURL: URL) async throws -> String {
        guard ItemKind.classify(url: imageURL) == .image else {
            throw PipelineError.unsupportedInput("\(imageURL.lastPathComponent) is not an image")
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw PipelineError.failed("File not found: \(imageURL.lastPathComponent)")
        }
        if Task.isCancelled { throw PipelineError.cancelled }

        let box = RequestBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try Self.performOCR(at: imageURL, box: box))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func performOCR(at url: URL, box: RequestBox) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard box.install(request) else { throw PipelineError.cancelled }

        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if box.isCancelled { throw PipelineError.cancelled }
            throw PipelineError.failed("Text recognition failed: \(error.localizedDescription)")
        }
        if box.isCancelled { throw PipelineError.cancelled }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

/// Lets a cancelled Task cancel an in-flight Vision request.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Returns false if cancellation already happened.
    func install(_ request: VNRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        self.request = request
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let r = request
        lock.unlock()
        r?.cancel()
    }
}

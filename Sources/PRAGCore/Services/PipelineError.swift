import Foundation

public enum PipelineError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedInput(String)
    case encoderUnavailable(String)
    case notEnoughInputs(needed: Int, got: Int)
    case invalidChain(String)
    case failed(String)
    case cancelled
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let s): "Unsupported input: \(s)"
        case .encoderUnavailable(let s): "Encoder unavailable: \(s)"
        case .notEnoughInputs(let n, let g): "Needs \(n) files, got \(g)"
        case .invalidChain(let s): "Invalid pipeline: \(s)"
        case .failed(let s): s
        case .cancelled: "Cancelled"
        case .notImplemented(let s): "\(s) is not implemented yet"
        }
    }
}

public typealias ProgressHandler = @Sendable (Double) -> Void

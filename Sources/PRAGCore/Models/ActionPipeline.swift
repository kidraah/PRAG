import Foundation

public enum ImageFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case webp, png, jpeg, heic, avif

    public var fileExtension: String {
        switch self {
        case .webp: "webp"
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .avif: "avif"
        }
    }

    public var label: String {
        switch self {
        case .webp: "WebP"
        case .png: "PNG"
        case .jpeg: "JPG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        }
    }
}

public enum VideoPreset: String, Codable, Sendable, CaseIterable, Hashable {
    case p720, p1080

    public var label: String { self == .p720 ? "720p" : "1080p" }
}

/// A single transformation. Steps are pure descriptions; services execute them.
public enum ActionStep: Codable, Sendable, Hashable {
    // Images
    case stripMetadata
    case compressImage(quality: Double)      // 0...1
    case convertImage(ImageFormat)
    case resizeImage(maxDimension: Int)
    case ocrToClipboard                       // terminal: produces text
    // PDFs
    case mergePDFs                            // N → 1
    case compressPDF
    case extractPDFText                       // → .txt file
    case extractPDFImages                     // → images
    // Video
    case compressVideo(VideoPreset)
    case extractAudio                         // → .m4a
    case videoToGIF
    // Generic
    case zip                                  // N → 1

    public var title: String {
        switch self {
        case .stripMetadata: "Strip EXIF"
        case .compressImage: "Compress"
        case .convertImage(let f): "→ \(f.label)"
        case .resizeImage(let d): "Fit \(d)px"
        case .ocrToClipboard: "Copy Text (OCR)"
        case .mergePDFs: "Merge PDFs"
        case .compressPDF: "Compress PDF"
        case .extractPDFText: "Extract Text"
        case .extractPDFImages: "Extract Images"
        case .compressVideo(let p): "Compress \(p.label)"
        case .extractAudio: "Extract Audio"
        case .videoToGIF: "→ GIF"
        case .zip: "Zip"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .stripMetadata: "eye.slash"
        case .compressImage: "arrow.down.right.and.arrow.up.left"
        case .convertImage: "arrow.triangle.2.circlepath"
        case .resizeImage: "aspectratio"
        case .ocrToClipboard: "text.viewfinder"
        case .mergePDFs: "doc.on.doc"
        case .compressPDF: "arrow.down.doc"
        case .extractPDFText: "doc.plaintext"
        case .extractPDFImages: "photo.on.rectangle"
        case .compressVideo: "film"
        case .extractAudio: "waveform"
        case .videoToGIF: "photo.stack"
        case .zip: "doc.zipper"
        }
    }

    /// Kinds this step accepts as input.
    public var acceptedKinds: Set<ItemKind> {
        switch self {
        case .stripMetadata, .compressImage, .convertImage, .resizeImage, .ocrToClipboard: [.image]
        case .mergePDFs, .compressPDF, .extractPDFText, .extractPDFImages: [.pdf]
        case .compressVideo, .extractAudio, .videoToGIF: [.video]
        case .zip: Set(ItemKind.allCases)
        }
    }

    /// Kind produced (used to validate chains: each step must accept the previous output).
    public var outputKind: ItemKind? {
        switch self {
        case .stripMetadata, .compressImage, .convertImage, .resizeImage: .image
        case .ocrToClipboard: nil
        case .mergePDFs, .compressPDF: .pdf
        case .extractPDFText: .text
        case .extractPDFImages: .image
        case .compressVideo: .video
        case .extractAudio: .audio
        case .videoToGIF: .image
        case .zip: .archive
        }
    }

    /// Collapses N inputs into one output.
    public var isAggregating: Bool {
        switch self {
        case .mergePDFs, .zip: true
        default: false
        }
    }

    /// Produces text instead of files; must be the last step of a chain.
    public var isTerminalText: Bool { self == .ocrToClipboard }

    /// Minimum number of inputs required.
    public var minimumInputs: Int { self == .mergePDFs ? 2 : 1 }
}

/// An ordered chain of steps. A single action is just a one-step pipeline.
public struct ActionPipeline: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var symbol: String
    public var steps: [ActionStep]
    public var isPreset: Bool

    public init(id: String? = nil, name: String, symbol: String, steps: [ActionStep], isPreset: Bool = false) {
        self.id = id ?? steps.map(\.title).joined(separator: ">")
        self.name = name
        self.symbol = symbol
        self.steps = steps
        self.isPreset = isPreset
    }

    public static func single(_ step: ActionStep) -> ActionPipeline {
        ActionPipeline(name: step.title, symbol: step.symbol, steps: [step])
    }

    /// "Strip EXIF → Compress → → WebP" style breadcrumb.
    public var breadcrumb: String { steps.map(\.title).joined(separator: " › ") }

    /// A chain is valid if each step accepts the previous step's output and
    /// text-producing steps are last.
    public var isValidChain: Bool {
        guard !steps.isEmpty else { return false }
        for (i, step) in steps.enumerated() {
            if step.isTerminalText && i != steps.count - 1 { return false }
            if i > 0 {
                guard let prevOut = steps[i - 1].outputKind, step.acceptedKinds.contains(prevOut) else { return false }
            }
        }
        return true
    }

    /// Whether this pipeline can run on a selection with these kinds/count.
    public func isApplicable(kinds: Set<ItemKind>, count: Int) -> Bool {
        guard let first = steps.first, !kinds.isEmpty, isValidChain else { return false }
        return kinds.isSubset(of: first.acceptedKinds) && count >= first.minimumInputs
    }

    // MARK: Presets

    public static let webReady = ActionPipeline(
        id: "preset.webReady", name: "Web Ready", symbol: "globe",
        steps: [.stripMetadata, .resizeImage(maxDimension: 2400), .compressImage(quality: 0.78), .convertImage(.webp)],
        isPreset: true)

    public static let privacyClean = ActionPipeline(
        id: "preset.privacyClean", name: "Privacy Clean", symbol: "hand.raised",
        steps: [.stripMetadata, .convertImage(.jpeg)],
        isPreset: true)

    public static let submissionReady = ActionPipeline(
        id: "preset.submissionReady", name: "Submission Ready", symbol: "paperplane",
        steps: [.mergePDFs, .compressPDF],
        isPreset: true)

    public static let shareClip = ActionPipeline(
        id: "preset.shareClip", name: "Share Clip", symbol: "bubble.left.and.bubble.right",
        steps: [.compressVideo(.p720)],
        isPreset: true)

    public static let presets: [ActionPipeline] = [webReady, privacyClean, submissionReady, shareClip]
}

/// Picks what to offer for a given selection. Pure — easy to unit test.
public enum ActionCatalog {
    public static func singleActions(kinds: Set<ItemKind>, count: Int) -> [ActionStep] {
        guard !kinds.isEmpty else { return [] }
        var out: [ActionStep] = []
        if kinds == [.image] {
            out += [.compressImage(quality: 0.7), .convertImage(.webp), .convertImage(.png), .convertImage(.jpeg),
                    .stripMetadata, .ocrToClipboard]
        } else if kinds == [.pdf] {
            if count >= 2 { out.append(.mergePDFs) }
            out += [.compressPDF, .extractPDFText, .extractPDFImages]
        } else if kinds == [.video] {
            out += [.compressVideo(.p720), .compressVideo(.p1080), .extractAudio, .videoToGIF]
        }
        out.append(.zip)
        return out
    }

    public static func presets(kinds: Set<ItemKind>, count: Int) -> [ActionPipeline] {
        ActionPipeline.presets.filter { $0.isApplicable(kinds: kinds, count: count) }
    }
}

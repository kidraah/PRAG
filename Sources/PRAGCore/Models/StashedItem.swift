import Foundation
import UniformTypeIdentifiers

/// Coarse classification used to decide which actions apply to a selection.
public enum ItemKind: String, Codable, Sendable, CaseIterable, Hashable {
    case image, pdf, video, audio, text, folder, code, archive, other

    public static func classify(_ type: UTType?, isDirectory: Bool = false) -> ItemKind {
        if isDirectory { return .folder }
        guard let type else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .zip) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) { return .code }
        if type.conforms(to: .text) { return .text }
        return .other
    }

    public static func classify(url: URL) -> ItemKind {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return classify(type, isDirectory: values?.isDirectory ?? false)
    }
}

/// Where an item on the shelf came from.
public enum ItemOrigin: String, Codable, Sendable, Hashable {
    case dropped      // user dragged it onto the shelf
    case screenshot   // auto-caught from the screenshot folder
    case processed    // output of an action/pipeline (lives in our workspace)
    case clipboard    // text/URL dropped and materialized to a file
}

/// Before/after byte sizes for a processed item. Drives the "-64% · 5.1 MB → 1.8 MB" badge.
public struct ByteDelta: Codable, Sendable, Hashable {
    public var before: Int64
    public var after: Int64

    public init(before: Int64, after: Int64) {
        self.before = before
        self.after = after
    }

    /// Fractional change: negative means smaller. -0.64 == 64% smaller.
    public var ratio: Double {
        guard before > 0 else { return 0 }
        return Double(after - before) / Double(before)
    }

    public var isSaving: Bool { after < before }

    /// "-64%" / "+12%" / "±0%"
    public var percentString: String {
        var pct = Int((ratio * 100).rounded())
        // Never claim -100% while a file still exists, or ±0% when sizes differ.
        if pct <= -100 && after > 0 { pct = -99 }
        if pct == 0 {
            if after == before { return "±0%" }
            return after < before ? "-<1%" : "+<1%"
        }
        return pct > 0 ? "+\(pct)%" : "\(pct)%"
    }

    /// "5.1 MB → 1.8 MB"
    public var summary: String {
        "\(ByteDelta.format(before)) → \(ByteDelta.format(after))"
    }

    public static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}

/// One item on the shelf. Items never own the user's original file: removing an item
/// from the shelf never touches the source on disk. Processed outputs live in our workspace.
public struct StashedItem: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    /// The file this shelf item currently represents (original for dropped items,
    /// the output file in the workspace for processed items).
    public var url: URL
    /// For processed items, the source file the chain started from.
    public var sourceURL: URL?
    /// Security-scoped bookmark for `url` so it survives restarts.
    public var bookmark: Data?
    public var displayName: String
    /// UTType identifier, e.g. "public.png".
    public var contentTypeIdentifier: String
    public var kind: ItemKind
    public var byteSize: Int64
    public var origin: ItemOrigin
    /// Steps that produced this item (empty for originals). Shown as lineage chips.
    public var appliedSteps: [ActionStep]
    /// Set for processed items.
    public var delta: ByteDelta?
    public var addedAt: Date
    /// User group (tab) this item is parked in; nil = Recent.
    public var groupID: UUID?

    public init(
        id: UUID = UUID(),
        url: URL,
        sourceURL: URL? = nil,
        bookmark: Data? = nil,
        displayName: String? = nil,
        contentTypeIdentifier: String? = nil,
        kind: ItemKind? = nil,
        byteSize: Int64? = nil,
        origin: ItemOrigin = .dropped,
        appliedSteps: [ActionStep] = [],
        delta: ByteDelta? = nil,
        addedAt: Date = Date(),
        groupID: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.sourceURL = sourceURL
        self.bookmark = bookmark
        self.displayName = displayName ?? url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        self.contentTypeIdentifier = contentTypeIdentifier ?? type?.identifier ?? UTType.data.identifier
        self.kind = kind ?? ItemKind.classify(url: url)
        self.byteSize = byteSize ?? StashedItem.fileSize(at: url)
        self.origin = origin
        self.appliedSteps = appliedSteps
        self.delta = delta
        self.addedAt = addedAt
        self.groupID = groupID
    }

    public var contentType: UTType? { UTType(contentTypeIdentifier) }
    public var isProcessed: Bool { origin == .processed }

    /// Recursive size for folders, plain size for files. 0 if unreadable.
    public static func fileSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Int64(size)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}

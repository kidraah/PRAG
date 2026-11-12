import Foundation

// Public API contract — the app target depends on these signatures.
// Workspace root: ~/Library/Application Support/NotchPipe/ (overridable for tests).
//
// Layout:
//   <root>/shelf.json            persisted shelf (ISO8601 dates, atomic writes)
//   <root>/Workspace/<UUID>/     one directory per pipeline step output
//
// SAFETY: nothing outside `<root>/Workspace` is ever deleted by this type.
public actor StashStorageService {
    public let rootURL: URL

    /// `<root>/Workspace` — every processed output lives below this directory.
    public nonisolated var workspaceURL: URL {
        rootURL.appendingPathComponent("Workspace", isDirectory: true)
    }

    /// `<root>/shelf.json`
    public nonisolated var shelfURL: URL {
        rootURL.appendingPathComponent("shelf.json", isDirectory: false)
    }

    public init(rootURL: URL? = nil) {
        let resolved = rootURL ?? StashStorageService.defaultRootURL()
        self.rootURL = resolved
        let fm = FileManager.default
        try? fm.createDirectory(at: resolved, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resolved.appendingPathComponent("Workspace", isDirectory: true),
                                withIntermediateDirectories: true)
    }

    /// `~/Library/Application Support/NotchPipe`
    public static func defaultRootURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("NotchPipe", isDirectory: true)
    }

    // MARK: Workspace

    /// Fresh, empty, uniquely-named directory under <root>/Workspace/ for one step's output.
    public func makeStepDirectory() throws -> URL {
        let dir = workspaceURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw PipelineError.failed("Could not create workspace directory: \(error.localizedDescription)")
        }
        return dir
    }

    /// True if `url` lives strictly inside our workspace (symlinks and `..` are resolved first).
    public nonisolated func isWorkspaceURL(_ url: URL) -> Bool {
        workspaceRelativeComponents(of: url) != nil
    }

    /// Removes a step directory (or anything inside the workspace). No-op for URLs outside the workspace.
    @discardableResult
    public func removeWorkspaceItem(at url: URL) -> Bool {
        guard isWorkspaceURL(url) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Deletes workspace output for a processed item (never touches non-workspace files).
    ///
    /// The item's file is removed; its step directory is removed too once nothing else lives in it
    /// (several outputs of one step — e.g. extracted PDF pages — can share a directory).
    public func discardOutput(of item: StashedItem) {
        guard let comps = workspaceRelativeComponents(of: item.url), let first = comps.first else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: item.url)
        // `first` is the step directory name. Remove the directory itself once it is empty.
        let stepDir = workspaceURL.appendingPathComponent(first, isDirectory: true)
        guard isWorkspaceURL(stepDir) else { return }
        let remaining = (try? fm.contentsOfDirectory(atPath: stepDir.path)) ?? []
        if remaining.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: stepDir)
        }
    }

    /// Removes workspace dirs not referenced by `keeping` and older than `age`.
    public func purge(keeping: [StashedItem], olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey],
            options: []) else { return }

        var referenced = Set<String>()
        for item in keeping {
            for url in [item.url, item.sourceURL].compactMap({ $0 }) {
                if let first = workspaceRelativeComponents(of: url)?.first { referenced.insert(first) }
            }
        }
        let cutoff = Date().addingTimeInterval(-age)
        for child in children {
            let name = child.lastPathComponent
            if referenced.contains(name) { continue }
            let values = try? child.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let stamp = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
            if stamp <= cutoff {
                if isWorkspaceURL(child) { try? fm.removeItem(at: child) }
            }
        }
    }

    // MARK: Persistence

    /// Persist the shelf (JSON at <root>/shelf.json, atomic).
    public func save(_ items: [StashedItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(items)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: shelfURL, options: .atomic)
    }

    /// Restore the shelf. Resolves bookmarks, refreshes sizes and drops items whose files vanished.
    public func load() -> [StashedItem] {
        guard let data = try? Data(contentsOf: shelfURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([StashedItem].self, from: data) else { return [] }

        let fm = FileManager.default
        var result: [StashedItem] = []
        for var item in stored {
            if let bookmark = item.bookmark, let resolved = StashStorageService.resolve(bookmark) {
                let movedURL = resolved.url
                let samePlace = movedURL.resolvingSymlinksInPath().path == item.url.resolvingSymlinksInPath().path
                if !samePlace && fm.fileExists(atPath: movedURL.path) && !StashStorageService.isInTrash(movedURL) {
                    if item.displayName == item.url.lastPathComponent {
                        item.displayName = movedURL.lastPathComponent
                    }
                    item.url = movedURL
                }
                if resolved.isStale, let fresh = makeBookmark(for: item.url) {
                    item.bookmark = fresh
                }
            }
            guard fm.fileExists(atPath: item.url.path), !StashStorageService.isInTrash(item.url) else { continue }
            item.byteSize = StashedItem.fileSize(at: item.url)
            result.append(item)
        }
        return result
    }

    // MARK: Bookmarks

    /// Security-scoped bookmark when possible, plain bookmark otherwise (the app is not sandboxed today).
    public nonisolated func makeBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark (scoped or plain). Stale bookmarks still resolve to the file's current location.
    public nonisolated func resolveBookmark(_ data: Data) -> URL? {
        StashStorageService.resolve(data)?.url
    }

    // MARK: Internals

    private static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        let attempts: [URL.BookmarkResolutionOptions] = [
            [.withSecurityScope, .withoutUI, .withoutMounting],
            [.withoutUI, .withoutMounting],
        ]
        for options in attempts {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return (url, stale)
            }
        }
        return nil
    }

    private static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash")
    }

    /// Path components of `url` relative to the workspace, or nil when `url` is not strictly inside it.
    private nonisolated func workspaceRelativeComponents(of url: URL) -> [String]? {
        let workspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard target.count > workspace.count, Array(target.prefix(workspace.count)) == workspace else { return nil }
        return Array(target.dropFirst(workspace.count))
    }
}

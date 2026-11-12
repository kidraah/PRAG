import Testing
import Foundation
@testable import NotchPipeCore

@Test func storageCreatesWorkspaceAndUniqueStepDirectories() async throws {
    let root = try makeTempDir("store")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = StashStorageService(rootURL: root.appendingPathComponent("NotchPipe"))
    let d1 = try await storage.makeStepDirectory()
    let d2 = try await storage.makeStepDirectory()
    #expect(d1 != d2)
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: d1.path, isDirectory: &isDir) && isDir.boolValue)
    #expect(d1.deletingLastPathComponent().lastPathComponent == "Workspace")
    #expect(d1.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "NotchPipe")
    #expect(UUID(uuidString: d1.lastPathComponent) != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: d1.path).isEmpty)
}

@Test func storageDefaultRootIsApplicationSupport() {
    let url = StashStorageService.defaultRootURL()
    #expect(url.path.hasSuffix("Library/Application Support/NotchPipe"))
}

@Test func storageSaveLoadRoundTrip() async throws {
    let root = try makeTempDir("store")
    let files = try makeTempDir("files")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: files) }
    let storage = StashStorageService(rootURL: root)

    let a = try writeFile(files, "a.png", bytes: 123)
    let b = try writeFile(files, "b.pdf", bytes: 456)
    var itemA = StashedItem(url: a, bookmark: storage.makeBookmark(for: a), origin: .screenshot)
    itemA.appliedSteps = [.stripMetadata, .convertImage(.webp), .compressImage(quality: 0.5)]
    itemA.delta = ByteDelta(before: 300, after: 123)
    var itemB = StashedItem(url: b, origin: .dropped)
    itemB.sourceURL = a

    try await storage.save([itemA, itemB])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("shelf.json").path))

    let loaded = await storage.load()
    #expect(loaded.count == 2)
    #expect(loaded.map(\.id) == [itemA.id, itemB.id])
    #expect(loaded[0].appliedSteps == itemA.appliedSteps)
    #expect(loaded[0].delta == itemA.delta)
    #expect(loaded[0].origin == .screenshot)
    #expect(loaded[0].byteSize == 123)
    #expect(loaded[1].sourceURL == a)
    #expect(abs(loaded[0].addedAt.timeIntervalSince(itemA.addedAt)) < 1)   // ISO8601 drops sub-second precision

    // The file is ISO8601 JSON.
    let json = try String(contentsOf: root.appendingPathComponent("shelf.json"), encoding: .utf8)
    #expect(json.contains("T") && json.contains("Z"))
}

@Test func storageLoadRefreshesSizeAndDropsMissingFiles() async throws {
    let root = try makeTempDir("store")
    let files = try makeTempDir("files")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: files) }
    let storage = StashStorageService(rootURL: root)
    let keep = try writeFile(files, "keep.txt", bytes: 10)
    let gone = try writeFile(files, "gone.txt", bytes: 10)
    try await storage.save([StashedItem(url: keep), StashedItem(url: gone)])

    try Data(repeating: 1, count: 99).write(to: keep)         // grow
    try FileManager.default.removeItem(at: gone)

    let loaded = await storage.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].url == keep)
    #expect(loaded[0].byteSize == 99)
}

@Test func storageLoadWithoutFileOrWithGarbageIsEmpty() async throws {
    let root = try makeTempDir("store")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = StashStorageService(rootURL: root)
    #expect(await storage.load().isEmpty)
    try Data("not json".utf8).write(to: root.appendingPathComponent("shelf.json"))
    #expect(await storage.load().isEmpty)
}

@Test func storageBookmarkFollowsMovedFile() async throws {
    let root = try makeTempDir("store")
    let files = try makeTempDir("files")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: files) }
    let storage = StashStorageService(rootURL: root)
    let original = try writeFile(files, "doc.txt", bytes: 20)
    let bookmark = try #require(storage.makeBookmark(for: original))
    #expect(storage.resolveBookmark(bookmark)?.resolvingSymlinksInPath().path == original.resolvingSymlinksInPath().path)

    try await storage.save([StashedItem(url: original, bookmark: bookmark)])
    let moved = files.appendingPathComponent("renamed.txt")
    try FileManager.default.moveItem(at: original, to: moved)

    let loaded = await storage.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].url.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
    #expect(loaded[0].displayName == "renamed.txt")

    #expect(storage.resolveBookmark(Data([1, 2, 3])) == nil)
}

@Test func storageIsWorkspaceURL() async throws {
    let root = try makeTempDir("store")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = StashStorageService(rootURL: root)
    let dir = try await storage.makeStepDirectory()
    #expect(storage.isWorkspaceURL(dir))
    #expect(storage.isWorkspaceURL(dir.appendingPathComponent("x.png")))
    #expect(!storage.isWorkspaceURL(storage.workspaceURL))                      // the workspace itself is not "inside"
    #expect(!storage.isWorkspaceURL(root))
    #expect(!storage.isWorkspaceURL(root.appendingPathComponent("shelf.json")))
    #expect(!storage.isWorkspaceURL(root.appendingPathComponent("WorkspaceEvil/x")))   // prefix lookalike
    #expect(!storage.isWorkspaceURL(dir.appendingPathComponent("../../../etc/passwd")))
    #expect(!storage.isWorkspaceURL(URL(fileURLWithPath: "/etc/hosts")))
}

@Test func storageDiscardOutputOnlyDeletesInsideWorkspace() async throws {
    let root = try makeTempDir("store")
    let outside = try makeTempDir("outside")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let storage = StashStorageService(rootURL: root)

    // Processed output in the workspace: file and its (then empty) step dir are removed.
    let step = try await storage.makeStepDirectory()
    let out = try writeFile(step, "out.webp", bytes: 10)
    await storage.discardOutput(of: StashedItem(url: out, origin: .processed))
    #expect(!FileManager.default.fileExists(atPath: out.path))
    #expect(!FileManager.default.fileExists(atPath: step.path))

    // Sibling outputs sharing a step dir survive.
    let shared = try await storage.makeStepDirectory()
    let p1 = try writeFile(shared, "p1.png", bytes: 5)
    let p2 = try writeFile(shared, "p2.png", bytes: 5)
    await storage.discardOutput(of: StashedItem(url: p1, origin: .processed))
    #expect(!FileManager.default.fileExists(atPath: p1.path))
    #expect(FileManager.default.fileExists(atPath: p2.path))

    // An item pointing at the user's own file (outside the workspace) is NEVER deleted.
    let precious = try writeFile(outside, "precious.png", bytes: 5)
    await storage.discardOutput(of: StashedItem(url: precious, origin: .dropped))
    await storage.discardOutput(of: StashedItem(url: precious, origin: .processed))
    #expect(FileManager.default.fileExists(atPath: precious.path))

    // Traversal tricks and the workspace/root themselves are refused too.
    let sneaky = shared.appendingPathComponent("../../../\(outside.lastPathComponent)/precious.png")
    await storage.discardOutput(of: StashedItem(url: sneaky, origin: .processed))
    await storage.discardOutput(of: StashedItem(url: storage.workspaceURL, origin: .processed))
    await storage.discardOutput(of: StashedItem(url: root, origin: .processed))
    #expect(FileManager.default.fileExists(atPath: precious.path))
    #expect(FileManager.default.fileExists(atPath: storage.workspaceURL.path))
    #expect(FileManager.default.fileExists(atPath: p2.path))

    // A symlink inside the workspace pointing outside must not delete its target.
    let linkDir = try await storage.makeStepDirectory()
    let link = linkDir.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
    await storage.discardOutput(of: StashedItem(url: link, origin: .processed))
    #expect(FileManager.default.fileExists(atPath: precious.path))

    // removeWorkspaceItem has the same guard.
    #expect(await storage.removeWorkspaceItem(at: precious) == false)
    #expect(FileManager.default.fileExists(atPath: precious.path))
}

@Test func storagePurgeRemovesOnlyOldUnreferencedDirs() async throws {
    let root = try makeTempDir("store")
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = StashStorageService(rootURL: root)

    let referenced = try await storage.makeStepDirectory()
    let refFile = try writeFile(referenced, "keep.png", bytes: 5)
    let orphanOld = try await storage.makeStepDirectory()
    try writeFile(orphanOld, "x.png", bytes: 5)
    let orphanFresh = try await storage.makeStepDirectory()
    try writeFile(orphanFresh, "y.png", bytes: 5)

    // Age the "old" and referenced dirs by an hour.
    let past = Date().addingTimeInterval(-3600)
    for d in [orphanOld, referenced] {
        try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: d.path)
    }
    let keeper = StashedItem(url: refFile, origin: .processed)

    await storage.purge(keeping: [keeper], olderThan: 60)
    #expect(FileManager.default.fileExists(atPath: referenced.path))        // referenced → kept
    #expect(!FileManager.default.fileExists(atPath: orphanOld.path))        // old + unreferenced → purged
    #expect(FileManager.default.fileExists(atPath: orphanFresh.path))       // too young → kept
}

import Testing
import Foundation
@testable import PRAGCore

private func unzipList(_ zip: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    p.arguments = ["-Z1", zip.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "unzip failed")
    // --sequesterRsrc adds __MACOSX/ AppleDouble entries for extended attributes; they are not content.
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
        .filter { !$0.hasPrefix("__MACOSX") }.joined(separator: "\n")
}

@Test func zipSingleFileIsNamedAfterInput() async throws {
    let src = try makeTempDir("zip-src")
    let out = try makeTempDir("zip-out")
    defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
    let file = try writeFile(src, "notes.txt", bytes: 2000)

    let zip = try await ArchiveService().zip([file], into: out)
    #expect(zip.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
    #expect(zip.lastPathComponent == "notes.txt.zip")
    let listing = try unzipList(zip)
    #expect(listing.split(separator: "\n").map(String.init) == ["notes.txt"])   // top level, no wrapper folder
    #expect(fileBytes(file) == 2000)                                    // source untouched
}

@Test func zipFolderKeepsParent() async throws {
    let src = try makeTempDir("zip-src")
    let out = try makeTempDir("zip-out")
    defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
    let folder = src.appendingPathComponent("Docs", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeFile(folder, "a.txt", bytes: 10)
    try writeFile(folder, "b.txt", bytes: 10)

    let zip = try await ArchiveService().zip([folder], into: out)
    #expect(zip.lastPathComponent == "Docs.zip")
    let listing = try unzipList(zip)
    #expect(listing.contains("Docs/a.txt"))
    #expect(listing.contains("Docs/b.txt"))
}

@Test func zipMultipleInputsMakesArchiveZipWithSingleTopLevelFolder() async throws {
    let src = try makeTempDir("zip-src")
    let src2 = try makeTempDir("zip-src2")
    let out = try makeTempDir("zip-out")
    defer { for d in [src, src2, out] { try? FileManager.default.removeItem(at: d) } }
    let a = try writeFile(src, "photo.png", bytes: 500)
    let b = try writeFile(src2, "photo.png", bytes: 700)               // same name, different folder
    let c = try writeFile(src, "report.pdf", bytes: 900)

    let zip = try await ArchiveService().zip([a, b, c], into: out)
    #expect(zip.lastPathComponent == "Archive.zip")
    let listing = try unzipList(zip)
    #expect(listing.contains("Archive/photo.png"))
    #expect(listing.contains("Archive/photo 2.png"))
    #expect(listing.contains("Archive/report.pdf"))
    let entries = Set(listing.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") })
    #expect(entries == ["Archive/photo.png", "Archive/photo 2.png", "Archive/report.pdf"])
    #expect(listing.split(separator: "\n").allSatisfy { $0.hasPrefix("Archive") })   // single top-level folder
    // sources intact, staging folder cleaned up
    #expect(fileBytes(a) == 500 && fileBytes(b) == 700 && fileBytes(c) == 900)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Archive.zip"])
}

@Test func zipRoundTripsContent() async throws {
    let src = try makeTempDir("zip-src")
    let out = try makeTempDir("zip-out")
    let extract = try makeTempDir("zip-extract")
    defer { for d in [src, out, extract] { try? FileManager.default.removeItem(at: d) } }
    let file = try writeFile(src, "data.bin", bytes: 4096, fill: 0x7F)
    let zip = try await ArchiveService().zip([file], into: out)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    p.arguments = ["-q", zip.path, "-d", extract.path]
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    let restored = try Data(contentsOf: extract.appendingPathComponent("data.bin"))
    #expect(restored == Data(repeating: 0x7F, count: 4096))
}

@Test func zipErrors() async throws {
    let out = try makeTempDir("zip-out")
    defer { try? FileManager.default.removeItem(at: out) }
    await #expect(throws: PipelineError.notEnoughInputs(needed: 1, got: 0)) {
        _ = try await ArchiveService().zip([], into: out)
    }
    do {
        _ = try await ArchiveService().zip([out.appendingPathComponent("missing.txt")], into: out)
        Issue.record("should throw")
    } catch let e as PipelineError {
        guard case .failed = e else { Issue.record("wrong error \(e)"); return }
    }
}

@Test func zipHonorsCancellation() async throws {
    let src = try makeTempDir("zip-src")
    let out = try makeTempDir("zip-out")
    defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
    let file = try writeFile(src, "x.txt", bytes: 10)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ArchiveService().zip([file], into: out)
    }
    do { _ = try await task.value; Issue.record("should throw") }
    catch let e as PipelineError { #expect(e == .cancelled) }
}

import Foundation

// Public API contract — the app target depends on these signatures.
public struct ArchiveService: Sendable {
    public init() {}

    /// Zips files/folders into `<directory>/Archive.zip` (or `<name>.zip` for a single input, where
    /// `<name>` is the item's full file name, like Finder: `photo.png` → `photo.png.zip`).
    /// Multiple inputs are staged in a temporary `Archive/` folder first, so the zip has a single
    /// top-level folder. Uses `/usr/bin/ditto`; cancelling the Task terminates the process.
    public func zip(_ inputs: [URL], into directory: URL) async throws -> URL {
        guard !inputs.isEmpty else { throw PipelineError.notEnoughInputs(needed: 1, got: 0) }
        let fm = FileManager.default
        for input in inputs where !fm.fileExists(atPath: input.path) {
            throw PipelineError.failed("File not found: \(input.lastPathComponent)")
        }
        if Task.isCancelled { throw PipelineError.cancelled }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let source: URL
        let outputName: String
        var stagingRoot: URL?
        defer { if let stagingRoot { try? fm.removeItem(at: stagingRoot) } }

        if inputs.count == 1 {
            source = inputs[0]
            outputName = inputs[0].lastPathComponent + ".zip"
        } else {
            let root = fm.temporaryDirectory.appendingPathComponent("NotchPipe-zip-\(UUID().uuidString)", isDirectory: true)
            let staging = root.appendingPathComponent("Archive", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            stagingRoot = root
            var used = Set<String>()
            for input in inputs {
                if Task.isCancelled { throw PipelineError.cancelled }
                let name = Self.uniqueName(input.lastPathComponent, used: &used)
                let target = staging.appendingPathComponent(name)
                do {
                    try fm.linkItem(at: input, to: target)          // hard link (files, same volume)
                } catch {
                    try fm.copyItem(at: input, to: target)          // APFS clone / plain copy otherwise
                }
            }
            source = staging
            outputName = "Archive.zip"
        }

        let output = directory.appendingPathComponent(outputName)
        try? fm.removeItem(at: output)
        // --keepParent embeds the *parent directory's* name; for a lone file that would wrap it in the
        // folder it happened to live in, so only folders (and the staging folder) keep their parent.
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)
        try await Self.ditto(source: source, destination: output, keepParent: isDir.boolValue)
        guard fm.fileExists(atPath: output.path) else { throw PipelineError.failed("Archive was not created") }
        return output
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        if used.insert(name).inserted { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    private static func ditto(source: URL, destination: URL, keepParent: Bool) async throws {
        let runner = ProcessRunner()
        do {
            try await runner.run(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc"] + (keepParent ? ["--keepParent"] : []) + [source.path, destination.path])
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// Runs one external process to completion; cancelling the surrounding Task terminates it.
final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(executable: String, arguments: [String]) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = errPipe

                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: PipelineError.cancelled)
                    return
                }
                self.process = process
                lock.unlock()

                process.terminationHandler = { [self] proc in
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock()
                    let wasCancelled = cancelled
                    self.process = nil
                    lock.unlock()
                    if wasCancelled {
                        continuation.resume(throwing: PipelineError.cancelled)
                    } else if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let message = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        continuation.resume(throwing: PipelineError.failed(
                            message.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(proc.terminationStatus)" : message))
                    }
                }
                do {
                    try process.run()
                } catch {
                    lock.lock(); self.process = nil; lock.unlock()
                    process.terminationHandler = nil
                    continuation.resume(throwing: PipelineError.failed("Could not launch \(executable): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }
}

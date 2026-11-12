import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared plumbing for the media services: output naming, off-main execution, cancellation.
enum MediaSupport {

    // MARK: Output files

    /// Atomically reserves a fresh output file `<directory>/<baseName>.<ext>` (or `-1`, `-2`, ... on collision)
    /// by creating it with O_EXCL, so concurrent jobs can never pick the same name. The returned file exists
    /// (empty); callers overwrite it with their result and call `discard(_:)` on failure.
    static func reserveOutput(baseName: String, ext: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PipelineError.failed("Cannot create output folder: \(error.localizedDescription)")
        }
        let base = baseName.isEmpty ? "output" : baseName
        for n in 0..<100_000 {
            let name = n == 0 ? "\(base).\(ext)" : "\(base)-\(n).\(ext)"
            let url = directory.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                return url
            }
            if errno != EEXIST {
                throw PipelineError.failed("Cannot create \(name): \(String(cString: strerror(errno)))")
            }
        }
        throw PipelineError.failed("Could not find a free output name for \(base).\(ext)")
    }

    static func reserveOutput(forInput input: URL, suffix: String = "", ext: String, in directory: URL) throws -> URL {
        try reserveOutput(baseName: input.deletingPathExtension().lastPathComponent + suffix, ext: ext, in: directory)
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `data` into a reserved output; removes the reservation if anything goes wrong.
    static func write(_ data: Data, to reserved: URL) throws {
        do {
            try checkCancelled()
            try data.write(to: reserved, options: .atomic)
        } catch {
            discard(reserved)
            throw error
        }
    }

    static func requireReadable(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw PipelineError.unsupportedInput("\(url.lastPathComponent) does not exist or is a folder")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PipelineError.unsupportedInput("\(url.lastPathComponent) is not readable")
        }
    }

    // MARK: Concurrency

    static func checkCancelled() throws {
        if Task.isCancelled { throw PipelineError.cancelled }
    }

    /// Runs blocking work on a background thread, forwarding cancellation of the caller into the work
    /// (visible there as `Task.isCancelled`). Errors are normalised to `PipelineError`.
    static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { () throws -> T in
            try work()
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw normalize(error)
        }
    }

    static func normalize(_ error: Error) -> PipelineError {
        if let e = error as? PipelineError { return e }
        if error is CancellationError { return .cancelled }
        return .failed(error.localizedDescription)
    }
}

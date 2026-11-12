import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// AVFoundation implementations (async; heavy lifting happens inside AVFoundation's own queues).
enum VideoWork {

    // MARK: Export sessions

    /// Exports `asset` into a private scratch folder, then moves the result into the output folder.
    static func export(asset: AVAsset, presets: [String], fileType: AVFileType, ext: String,
                       input: URL, suffix: String, directory: URL,
                       progress: ProgressHandler?) async throws -> URL {
        // Pick the first preset that is compatible with this asset.
        var chosen: AVAssetExportSession?
        for p in presets {
            if await AVAssetExportSession.compatibility(ofExportPreset: p, with: asset, outputFileType: fileType),
               let s = AVAssetExportSession(asset: asset, presetName: p) {
                chosen = s
                break
            }
        }
        guard let session = chosen else {
            throw PipelineError.unsupportedInput("\(input.lastPathComponent) cannot be exported with the requested settings")
        }
        try MediaSupport.checkCancelled()

        let reserved = try MediaSupport.reserveOutput(forInput: input, suffix: suffix, ext: ext, in: directory)
        // Export into a private scratch folder: AVAssetExportSession drops side files next to its output and
        // cleans them up asynchronously after a cancel, which must never litter the user's output folder.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchPipeExport-\(UUID().uuidString)", isDirectory: true)
        let temp = scratch.appendingPathComponent("export.\(ext)")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            session.shouldOptimizeForNetworkUse = true
            try await run(session: session, to: temp, as: fileType, progress: progress)
            try MediaSupport.checkCancelled()
            let fm = FileManager.default
            try? fm.removeItem(at: reserved)
            try fm.moveItem(at: temp, to: reserved)
            progress?(1)
            return reserved
        } catch {
            MediaSupport.discard(reserved)
            throw MediaSupport.normalize(error)
        }
    }

    /// AVAssetExportSession is documented as safe to observe/cancel from any thread.
    private struct SessionBox: @unchecked Sendable { let session: AVAssetExportSession }

    private static func run(session raw: AVAssetExportSession, to url: URL, as type: AVFileType,
                            progress: ProgressHandler?) async throws {
        let box = SessionBox(session: raw)
        if #available(macOS 15, *) {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await state in box.session.states(updateInterval: 0.1) {
                            if case .exporting(let p) = state { progress?(min(1, max(0, p.fractionCompleted))) }
                        }
                    }
                    do {
                        try await box.session.export(to: url, as: type)
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                    group.cancelAll()
                }
            } onCancel: {
                box.session.cancelExport()
            }
        } else {
            try await legacyExport(box, to: url, as: type, progress: progress)
        }
    }

    /// macOS 14 path: exportAsynchronously + progress polling.
    private static func legacyExport(_ box: SessionBox, to url: URL, as type: AVFileType,
                                     progress: ProgressHandler?) async throws {
        box.session.outputURL = url
        box.session.outputFileType = type
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.session.exportAsynchronously {
                    let session = box.session
                    switch session.status {
                    case .completed: cont.resume()
                    case .cancelled: cont.resume(throwing: PipelineError.cancelled)
                    default: cont.resume(throwing: session.error ?? PipelineError.failed("Export failed"))
                    }
                }
                // Progress polling until the session finishes.
                Task.detached {
                    let session = box.session
                    while session.status == .waiting || session.status == .exporting {
                        progress?(Double(session.progress))
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    // MARK: GIF

    static func toGIF(_ input: URL, into directory: URL, maxWidth: Int, fps: Double,
                      progress: ProgressHandler?) async throws -> URL {
        try MediaSupport.requireReadable(input)
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw PipelineError.unsupportedInput("\(input.lastPathComponent) has no video track")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PipelineError.unsupportedInput("video has no duration") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = natural.applying(transform)
        let vw = abs(oriented.width), vh = abs(oriented.height)
        guard vw > 0, vh > 0 else { throw PipelineError.unsupportedInput("video has no dimensions") }

        let rate = min(30, max(1, fps))
        let clipSeconds = min(duration, 10)
        let frameCount = max(1, min(150, Int((clipSeconds * rate).rounded(.down))))
        let step = clipSeconds / Double(frameCount)

        let width = max(1, min(maxWidth, Int(vw)))
        let height = max(1, Int((Double(width) * Double(vh / vw)).rounded()))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: height)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = (0..<frameCount).map { CMTime(seconds: Double($0) * step, preferredTimescale: 600) }

        let reserved = try MediaSupport.reserveOutput(forInput: input, ext: "gif", in: directory)
        do {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil) else {
                throw PipelineError.encoderUnavailable("GIF")
            }
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
            // GIF delays have 1/100 s resolution.
            let delay = max(0.02, (step * 100).rounded() / 100)
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                              kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary

            var added = 0
            for await result in generator.images(for: times) {
                try MediaSupport.checkCancelled()
                switch result {
                case .success(_, let image, _):
                    CGImageDestinationAddImage(dest, image, frameProps)
                    added += 1
                case .failure(_, let error):
                    if added == 0 && times.count == 1 { throw error }
                    // Skip individual undecodable frames.
                }
                progress?(0.95 * Double(added) / Double(frameCount))
            }
            try MediaSupport.checkCancelled()
            guard added > 0 else { throw PipelineError.failed("Could not read any frames from \(input.lastPathComponent)") }
            guard CGImageDestinationFinalize(dest) else { throw PipelineError.failed("Could not write GIF") }
            try MediaSupport.write(data as Data, to: reserved)
            progress?(1)
            return reserved
        } catch {
            MediaSupport.discard(reserved)
            throw MediaSupport.normalize(error)
        }
    }
}

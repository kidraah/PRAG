import Foundation
@preconcurrency import AVFoundation

// Public API contract — the app target depends on these signatures.
// Must honour Task cancellation (cancel the export session) and report progress 0...1.
public struct VideoPipelineService: Sendable {
    public init() {}

    /// H.264 .mp4 at 1280x720 or 1920x1080 (never upscaled), optimised for network use.
    /// (H.264 rather than HEVC on purpose: the result is meant to be shared and plays everywhere.)
    public func compress(_ input: URL, preset: VideoPreset, into directory: URL, progress: ProgressHandler? = nil) async throws -> URL {
        try MediaSupport.requireReadable(input)
        let asset = AVURLAsset(url: input)
        do {
            guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw PipelineError.unsupportedInput("\(input.lastPathComponent) has no video track")
            }
        } catch let error as PipelineError {
            throw error
        } catch {
            throw PipelineError.unsupportedInput("\(input.lastPathComponent) is not a readable video")
        }
        let primary = preset == .p720 ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080
        return try await VideoWork.export(asset: asset, presets: [primary, AVAssetExportPresetMediumQuality],
                                          fileType: .mp4, ext: "mp4", input: input, suffix: "-compressed",
                                          directory: directory, progress: progress)
    }

    /// AAC audio track only, as "<name>.m4a". Throws `unsupportedInput` if the file has no audio.
    public func extractAudio(_ input: URL, into directory: URL, progress: ProgressHandler? = nil) async throws -> URL {
        try MediaSupport.requireReadable(input)
        let asset = AVURLAsset(url: input)
        let audio: [AVAssetTrack]
        do {
            audio = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw PipelineError.unsupportedInput("\(input.lastPathComponent) is not a readable media file")
        }
        guard !audio.isEmpty else {
            throw PipelineError.unsupportedInput("\(input.lastPathComponent) has no audio track")
        }
        return try await VideoWork.export(asset: asset, presets: [AVAssetExportPresetAppleM4A],
                                          fileType: .m4a, ext: "m4a", input: input, suffix: "",
                                          directory: directory, progress: progress)
    }

    /// Looping GIF: `fps` frames/s (max 10 s / 150 frames), scaled down to `maxWidth`.
    public func toGIF(_ input: URL, into directory: URL, maxWidth: Int = 640, fps: Double = 12, progress: ProgressHandler? = nil) async throws -> URL {
        do {
            return try await VideoWork.toGIF(input, into: directory, maxWidth: maxWidth, fps: fps, progress: progress)
        } catch {
            throw MediaSupport.normalize(error)
        }
    }
}

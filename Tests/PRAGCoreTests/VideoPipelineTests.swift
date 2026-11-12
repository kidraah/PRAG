import Testing
import Foundation
import AVFoundation
import ImageIO
@testable import PRAGCore

/// Thread-safe progress recorder.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite("Video pipeline")
struct VideoPipelineTests {
    let service = VideoPipelineService()

    @Test func compressProducesPlayableMP4() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try await MediaFixtures.makeVideo(in: dir, withAudio: true)
            let before = try MediaFixtures.bytes(input)
            let log = ProgressLog()
            let out = try await service.compress(input, preset: .p720, into: dir.appendingPathComponent("o"),
                                                 progress: { log.add($0) })
            #expect(out.lastPathComponent == "clip-compressed.mp4")
            let asset = AVURLAsset(url: out)
            #expect(try await asset.load(.isPlayable))
            let seconds = try await asset.load(.duration).seconds
            #expect(abs(seconds - 2) < 0.3)
            #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
            #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
            #expect(log.all.last == 1)
            #expect(log.all.allSatisfy { $0 >= 0 && $0 <= 1 })
            #expect(try MediaFixtures.bytes(input) == before)
            // no leftovers (partial files)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("o").path)
            #expect(files == ["clip-compressed.mp4"])
        }
    }

    @Test func compress1080DoesNotUpscale() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try await MediaFixtures.makeVideo(in: dir)
            let out = try await service.compress(input, preset: .p1080, into: dir.appendingPathComponent("o"))
            let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first!
            let size = try await track.load(.naturalSize)
            #expect(size.width <= 1920 && size.height <= 1080)
            #expect(size.width <= 640 + 16)
        }
    }

    @Test func extractAudioWritesM4A() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try await MediaFixtures.makeVideo(in: dir, withAudio: true)
            let out = try await service.extractAudio(input, into: dir.appendingPathComponent("o"))
            #expect(out.lastPathComponent == "clip.m4a")
            let asset = AVURLAsset(url: out)
            #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
            #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
            #expect(abs(try await asset.load(.duration).seconds - 2) < 0.3)
        }
    }

    @Test func extractAudioWithoutAudioTrackIsUnsupported() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try await MediaFixtures.makeVideo(in: dir, withAudio: false)
            do {
                _ = try await service.extractAudio(input, into: dir.appendingPathComponent("o"))
                Issue.record("expected unsupportedInput")
            } catch let e as PipelineError {
                guard case .unsupportedInput = e else { Issue.record("wrong error \(e)"); return }
            }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("o").path)) ?? []
            #expect(left.isEmpty)
        }
    }

    @Test func gifHasMultipleFramesAndLoopsForever() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try await MediaFixtures.makeVideo(in: dir)
            let before = try MediaFixtures.bytes(input)
            let log = ProgressLog()
            let out = try await service.toGIF(input, into: dir.appendingPathComponent("o"), maxWidth: 320, fps: 10,
                                              progress: { log.add($0) })
            #expect(out.lastPathComponent == "clip.gif")
            let src = CGImageSourceCreateWithURL(out as CFURL, nil)!
            #expect(CGImageSourceGetType(src) as String? == "com.compuserve.gif")
            let frames = CGImageSourceGetCount(src)
            #expect(frames > 1)
            #expect(frames == 20)   // 2 s at 10 fps
            let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            #expect((gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue == 0)
            let frameProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let delay = ((frameProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            #expect(delay != nil && abs(delay! - 0.1) < 0.011)
            #expect(MediaFixtures.pixelSize(of: out)?.w == 320)
            #expect(MediaFixtures.pixelSize(of: out)?.h == 180)
            #expect(log.all.last == 1)
            #expect(try MediaFixtures.bytes(input) == before)
        }
    }

    @Test func gifCapsAt150Frames() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try await MediaFixtures.makeVideo(in: dir, seconds: 12, width: 160, height: 90)
            let out = try await service.toGIF(input, into: dir.appendingPathComponent("o"), maxWidth: 160, fps: 30)
            let frames = CGImageSourceGetCount(CGImageSourceCreateWithURL(out as CFURL, nil)!)
            #expect(frames == 150)
        }
    }

    @Test func cancellingCompressStopsAndCleansUp() async throws {
        let dir = try MediaFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await MediaFixtures.makeVideo(in: dir, seconds: 4, width: 1920, height: 1080)
        let svc = service
        let outDir = dir.appendingPathComponent("o")
        let task = Task { try await svc.compress(input, preset: .p720, into: outDir) }
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("export finished before it could be cancelled")
        } catch let e as PipelineError {
            #expect(e == .cancelled)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        #expect(files.allSatisfy { !$0.hasPrefix(".") }, "leftovers: \(files)")
    }

    @Test func notAVideoIsRejected() async throws {
        try await MediaFixtures.withTempDir { dir in
            let bad = dir.appendingPathComponent("bad.mp4")
            try Data("not a video".utf8).write(to: bad)
            await #expect(throws: PipelineError.self) { _ = try await service.compress(bad, preset: .p720, into: dir.appendingPathComponent("o")) }
            await #expect(throws: PipelineError.self) { _ = try await service.toGIF(bad, into: dir.appendingPathComponent("o")) }
        }
    }
}


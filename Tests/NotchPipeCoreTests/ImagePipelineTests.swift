import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
@testable import NotchPipeCore

// MARK: - Shared fixtures (used by the PDF and Video tests too). Everything is generated at runtime.

enum MediaFixtures {

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchPipeMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs `body` with a fresh temp dir that is deleted afterwards.
    static func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    static func utType(of url: URL) -> String? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(s) as String?
    }

    static func properties(of url: URL) -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func pixelSize(of url: URL) -> (w: Int, h: Int)? {
        let p = properties(of: url)
        guard let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (w, h)
    }

    // MARK: Images

    static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// Gradient + random speckle + text. `noise` makes the JPEG big.
    static func makeImage(width: Int, height: Int, text: String = "NotchPipe", noise: Int = 4000,
                          alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1),
                                           CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.saveGState()
        if alpha { ctx.clip(to: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4)) }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.restoreGState()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<noise {
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: Int.random(in: 0..<width, using: &rng), y: Int.random(in: 0..<height, using: &rng),
                            width: Int.random(in: 2...12, using: &rng), height: Int.random(in: 2...12, using: &rng)))
        }
        drawText(text, in: ctx, at: CGPoint(x: CGFloat(width) * 0.1, y: CGFloat(height) * 0.45),
                 size: CGFloat(height) / 6, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        return ctx.makeImage()!
    }

    static var fakeMetadata: [CFString: Any] { [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FakeCam", kCGImagePropertyTIFFModel: "X1000",
                                         kCGImagePropertyTIFFSoftware: "SecretEditor 1.0"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note",
                                         kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
                                         kCGImagePropertyExifLensModel: "FakeLens 50mm"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "secret caption"],
    ] }

    @discardableResult
    static func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.95,
                           orientation: Int = 1, metadata: Bool = true) throws -> URL {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = metadata ? fakeMetadata : [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        if orientation != 1 { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PipelineError.failed("fixture write failed") }
        try (data as Data).write(to: url)
        return url
    }

    static func makeJPEG(in dir: URL, name: String = "photo.jpg", width: Int = 640, height: Int = 480,
                         noise: Int = 4000, quality: Double = 0.95, orientation: Int = 1) throws -> URL {
        try writeImage(makeImage(width: width, height: height, noise: noise), to: dir.appendingPathComponent(name),
                       type: .jpeg, quality: quality, orientation: orientation)
    }

    // MARK: PDFs

    static func makePDF(in dir: URL, name: String, pageTexts: [String], pageSize: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw PipelineError.failed("pdf fixture") }
        for t in pageTexts {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            drawText(t, in: ctx, at: CGPoint(x: 72, y: pageSize.height - 144), size: 28, color: CGColor(gray: 0, alpha: 1))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A "scanned" PDF: each page is one big (≈300 DPI) noisy JPEG.
    static func makeScanPDF(in dir: URL, name: String = "scan.pdf", pages: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let image = makeImage(width: 2480, height: 3508, text: "SCANNED PAGE", noise: 20000)
        let jpeg = NSMutableData()
        let d = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(d)
        let jpegImage = CGImage(jpegDataProviderSource: CGDataProvider(data: jpeg as CFData)!, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)!
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.draw(jpegImage, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    // MARK: Video

    /// 2-second 640x360 H.264 video (30 fps, moving gradient) with an optional silent AAC track.
    static func makeVideo(in dir: URL, name: String = "clip.mp4", seconds: Double = 2, withAudio: Bool = false,
                          width: Int = 640, height: Int = 360) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        let sampleRate = 44100.0
        var pcmFormat: CMAudioFormatDescription?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate, AVEncoderBitRateKey: 64_000,
            ])
            writer.add(input)
            aInput = input
            var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                   mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &pcmFormat)
        }
        guard writer.startWriting() else { throw writer.error ?? PipelineError.failed("video fixture") }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let frames = Int(seconds * Double(fps))
        let samplesPerFrame = Int(sampleRate) / fps
        // The writer interleaves by itself when each input is fed independently.
        let feeder = FixtureFeeder(writer: writer, vInput: vInput, adaptor: adaptor, aInput: aInput, pcmFormat: pcmFormat)
        async let videoDone: Void = feeder.feedVideo(frames: frames, fps: fps, width: width, height: height)
        async let audioDone: Void = feeder.feedAudio(frames: frames, samplesPerFrame: samplesPerFrame, sampleRate: sampleRate)
        try await videoDone
        try await audioDone
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PipelineError.failed("video fixture failed") }
        return url
    }
}

/// Feeds the video and audio inputs of an AVAssetWriter from independent tasks (AVFoundation objects are
/// used from one task each, so the unchecked Sendable is safe here).
final class FixtureFeeder: @unchecked Sendable {
    let writer: AVAssetWriter
    let vInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let aInput: AVAssetWriterInput?
    let pcmFormat: CMAudioFormatDescription?

    init(writer: AVAssetWriter, vInput: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         aInput: AVAssetWriterInput?, pcmFormat: CMAudioFormatDescription?) {
        self.writer = writer; self.vInput = vInput; self.adaptor = adaptor; self.aInput = aInput; self.pcmFormat = pcmFormat
    }

    private func waitReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? PipelineError.failed("video fixture failed") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func feedVideo(frames: Int, fps: Int, width: Int, height: Int) async throws {
        for i in 0..<frames {
            try await waitReady(vInput)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let o = y * stride + x * 4
                    base[o] = UInt8((x + i * 8) % 256)
                    base[o + 1] = UInt8((y * 255) / height)
                    base[o + 2] = UInt8((i * 255) / frames)
                    base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        vInput.markAsFinished()
    }

    func feedAudio(frames: Int, samplesPerFrame: Int, sampleRate: Double) async throws {
        guard let aInput, let pcmFormat else { return }
        for i in 0..<frames {
            try await waitReady(aInput)
            var block: CMBlockBuffer?
            let length = samplesPerFrame * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                               blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                               dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                               blockBufferOut: &block)
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length)
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(i * samplesPerFrame),
                                                                          timescale: CMTimeScale(sampleRate)),
                                            decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                 refcon: nil, formatDescription: pcmFormat, sampleCount: samplesPerFrame,
                                 sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                 sampleSizeArray: nil, sampleBufferOut: &sample)
            aInput.append(sample!)
        }
        aInput.markAsFinished()
    }
}

// MARK: - Image tests

@Suite("Image pipeline")
struct ImagePipelineTests {
    let service = ImagePipelineService()

    @Test func encoderAvailability() {
        #expect(ImagePipelineService.canEncode(.png))
        #expect(ImagePipelineService.canEncode(.jpeg))
        #expect(ImagePipelineService.canEncode(.webp))   // libwebp
        print("canEncode heic=\(ImagePipelineService.canEncode(.heic)) avif=\(ImagePipelineService.canEncode(.avif))")
    }

    @Test func fixtureHasMetadata() async throws {
        try await MediaFixtures.withTempDir { dir in
            let url = try MediaFixtures.makeJPEG(in: dir)
            let p = MediaFixtures.properties(of: url)
            #expect(p[kCGImagePropertyGPSDictionary] != nil)
            #expect(p[kCGImagePropertyExifDictionary] != nil)
        }
    }

    @Test func stripRemovesGPSAndExif() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir)
            let before = try MediaFixtures.bytes(input)
            let outDir = dir.appendingPathComponent("out")
            let out = try await service.stripMetadata(input, into: outDir)

            #expect(out.deletingLastPathComponent().path == outDir.path)
            #expect(out.lastPathComponent == "photo.jpg")
            let p = MediaFixtures.properties(of: out)
            #expect(p[kCGImagePropertyGPSDictionary] == nil)
            #expect(p[kCGImagePropertyIPTCDictionary] == nil)
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifUserComment] == nil)
            #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
            #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
            #expect(MediaFixtures.utType(of: out) == "public.jpeg")
            #expect(MediaFixtures.pixelSize(of: out)?.w == 640)
            #expect(try MediaFixtures.bytes(input) == before)
            // raw bytes must not contain the secrets either
            let raw = try MediaFixtures.bytes(out)
            #expect(raw.range(of: Data("FakeCam".utf8)) == nil)
            #expect(raw.range(of: Data("private note".utf8)) == nil)
        }
    }

    @Test func stripKeepsOrientationUpright() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir, width: 300, height: 200, orientation: 6)
            let out = try await service.stripMetadata(input, into: dir.appendingPathComponent("o"))
            let p = MediaFixtures.properties(of: out)
            #expect(p[kCGImagePropertyGPSDictionary] == nil)
            // Displayed orientation must still be "rotated 90°": either tag kept, or pixels baked (portrait).
            let orientation = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let size = MediaFixtures.pixelSize(of: out)!
            let displayedPortrait = orientation >= 5 ? size.w > size.h : size.h > size.w
            #expect(displayedPortrait)
        }
    }

    @Test func stripPNGAndWebP() async throws {
        try await MediaFixtures.withTempDir { dir in
            let png = dir.appendingPathComponent("shot.png")
            try MediaFixtures.writeImage(MediaFixtures.makeImage(width: 200, height: 100), to: png, type: .png)
            let out = try await service.stripMetadata(png, into: dir.appendingPathComponent("o"))
            #expect(MediaFixtures.utType(of: out) == "public.png")
            let p = MediaFixtures.properties(of: out)
            #expect(p[kCGImagePropertyGPSDictionary] == nil)
            #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)

            let webp = try await service.convert(png, to: .webp, quality: 0.8, into: dir.appendingPathComponent("w"))
            let stripped = try await service.stripMetadata(webp, into: dir.appendingPathComponent("w2"))
            #expect(stripped.pathExtension == "webp")
            #expect(MediaFixtures.utType(of: stripped) == "org.webmproject.webp")
        }
    }

    @Test func compressShrinksLargeJPEG() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir, name: "big.jpg", width: 2000, height: 1500, noise: 8000, quality: 0.98)
            let before = try MediaFixtures.bytes(input)
            let out = try await service.compress(input, quality: 0.4, into: dir.appendingPathComponent("o"))
            #expect(MediaFixtures.utType(of: out) == "public.jpeg")
            #expect(MediaFixtures.fileSize(out) < MediaFixtures.fileSize(input) / 2)
            #expect(MediaFixtures.pixelSize(of: out)?.w == 2000)
            #expect(try MediaFixtures.bytes(input) == before)
        }
    }

    @Test func compressPNGWithoutAlphaBecomesJPEG() async throws {
        try await MediaFixtures.withTempDir { dir in
            let png = dir.appendingPathComponent("flat.png")
            try MediaFixtures.writeImage(MediaFixtures.makeImage(width: 1200, height: 800, noise: 6000), to: png, type: .png, metadata: false)
            let out = try await service.compress(png, quality: 0.6, into: dir.appendingPathComponent("o"))
            #expect(MediaFixtures.utType(of: out) == "public.jpeg")
            #expect(out.pathExtension == "jpg")
            #expect(MediaFixtures.fileSize(out) < MediaFixtures.fileSize(png))
        }
    }

    @Test func compressPNGWithAlphaKeepsAlpha() async throws {
        try await MediaFixtures.withTempDir { dir in
            let png = dir.appendingPathComponent("logo.png")
            try MediaFixtures.writeImage(MediaFixtures.makeImage(width: 600, height: 400, noise: 500, alpha: true), to: png, type: .png, metadata: false)
            let out = try await service.compress(png, quality: 0.6, into: dir.appendingPathComponent("o"))
            let type = MediaFixtures.utType(of: out)
            #expect(type == "public.heic" || type == "public.png")
            if type == "public.heic" { #expect(out.pathExtension == "heic") }
            let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil)!
            let alphaInfo = img.alphaInfo
            #expect(alphaInfo != .none && alphaInfo != .noneSkipLast && alphaInfo != .noneSkipFirst)
        }
    }

    @Test func convertProducesRightTypeForEveryEncodableFormat() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir)
            let expected: [ImageFormat: String] = [.png: "public.png", .jpeg: "public.jpeg", .heic: "public.heic",
                                                   .avif: "public.avif", .webp: "org.webmproject.webp"]
            for format in ImageFormat.allCases where ImagePipelineService.canEncode(format) {
                let out = try await service.convert(input, to: format, quality: 0.8, into: dir.appendingPathComponent("o-\(format.rawValue)"))
                #expect(out.pathExtension == format.fileExtension, "\(format)")
                #expect(MediaFixtures.utType(of: out) == expected[format], "\(format)")
                #expect(MediaFixtures.pixelSize(of: out)?.w == 640, "\(format)")
            }
            for format in ImageFormat.allCases where !ImagePipelineService.canEncode(format) {
                await #expect(throws: PipelineError.self) {
                    _ = try await service.convert(input, to: format, quality: 0.8, into: dir.appendingPathComponent("x"))
                }
            }
        }
    }

    @Test func convertAlphaToJPEGFlattensOnWhite() async throws {
        try await MediaFixtures.withTempDir { dir in
            let png = dir.appendingPathComponent("a.png")
            try MediaFixtures.writeImage(MediaFixtures.makeImage(width: 200, height: 200, noise: 0, alpha: true), to: png, type: .png, metadata: false)
            let out = try await service.convert(png, to: .jpeg, quality: 0.95, into: dir.appendingPathComponent("o"))
            let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil)!
            // corner pixel (fully transparent in source) must be white
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 200, height: 200), byTiling: false)
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            #expect(px[0] > 240 && px[1] > 240 && px[2] > 240)
        }
    }

    @Test func webpLossyIsSmallerThanLossless() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir)
            let lossy = try await service.convert(input, to: .webp, quality: 0.5, into: dir.appendingPathComponent("a"))
            let lossless = try await service.convert(input, to: .webp, quality: 1.0, into: dir.appendingPathComponent("b"))
            #expect(MediaFixtures.fileSize(lossy) < MediaFixtures.fileSize(lossless))
        }
    }

    @Test func resizeRespectsMaxDimension() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir, width: 2000, height: 1000)
            let before = try MediaFixtures.bytes(input)
            let out = try await service.resize(input, maxDimension: 800, into: dir.appendingPathComponent("o"))
            let s = MediaFixtures.pixelSize(of: out)!
            #expect(max(s.w, s.h) <= 800)
            #expect(s.w == 800 && s.h == 400)
            #expect(MediaFixtures.utType(of: out) == "public.jpeg")

            // already smaller: size unchanged
            let same = try await service.resize(input, maxDimension: 5000, into: dir.appendingPathComponent("o2"))
            #expect(MediaFixtures.pixelSize(of: same)?.w == 2000)
            #expect(try MediaFixtures.bytes(input) == before)
        }
    }

    @Test func resizeBakesOrientation() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir, width: 300, height: 200, orientation: 6)
            let out = try await service.resize(input, maxDimension: 150, into: dir.appendingPathComponent("o"))
            let s = MediaFixtures.pixelSize(of: out)!
            #expect(s.h == 150 && s.w == 100)   // portrait after rotation
            let orientation = (MediaFixtures.properties(of: out)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            #expect(orientation == 1)
        }
    }

    @Test func outputNamesAreUnique() async throws {
        try await MediaFixtures.withTempDir { dir in
            let input = try MediaFixtures.makeJPEG(in: dir)
            let out = dir.appendingPathComponent("out")
            let a = try await service.resize(input, maxDimension: 100, into: out)
            let b = try await service.resize(input, maxDimension: 100, into: out)
            let c = try await service.resize(input, maxDimension: 100, into: out)
            #expect(a.lastPathComponent == "photo.jpg")
            #expect(b.lastPathComponent == "photo-1.jpg")
            #expect(c.lastPathComponent == "photo-2.jpg")
            // output into the input's own directory must never overwrite the input
            let d = try await service.resize(input, maxDimension: 100, into: dir)
            #expect(d.lastPathComponent == "photo-1.jpg")
        }
    }

    @Test func garbageInputThrowsUnsupported() async throws {
        try await MediaFixtures.withTempDir { dir in
            let bad = dir.appendingPathComponent("bad.jpg")
            try Data("not an image".utf8).write(to: bad)
            await #expect(throws: PipelineError.self) { _ = try await service.compress(bad, quality: 0.5, into: dir) }
            let missing = dir.appendingPathComponent("missing.png")
            await #expect(throws: PipelineError.self) { _ = try await service.stripMetadata(missing, into: dir) }
        }
    }

    @Test func cancellationThrowsCancelled() async throws {
        let dir = try MediaFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try MediaFixtures.makeJPEG(in: dir, name: "huge.jpg", width: 4000, height: 3000, noise: 20000)
        let svc = service
        let outDir = dir.appendingPathComponent("o")
        let task = Task { try await svc.convert(input, to: .webp, quality: 1.0, into: outDir) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let e as PipelineError {
            #expect(e == .cancelled)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        #expect(leftovers.isEmpty)
    }
}

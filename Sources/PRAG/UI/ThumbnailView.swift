import SwiftUI
import AppKit
import QuickLookThumbnailing

/// QuickLook thumbnails with a small in-memory cache (bounded, evicted under pressure).
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() { cache.countLimit = 160 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func thumbnail(for url: URL, side: CGFloat) async -> NSImage {
        if let hit = cached(url) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Generate at a fixed comfortable size so every view shares one cache entry.
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                                   scale: scale, representationTypes: .thumbnail)
        // Completion-handler API + an unchecked box: the async variant returns a non-Sendable
        // representation, which older Swift 6 compilers refuse to hand across actors.
        let boxed: ImageBox? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep.map { ImageBox(image: $0.nsImage) })
            }
        }
        let image = boxed?.image ?? NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// NSImage is immutable once QuickLook hands it over; safe to move to the main actor.
private struct ImageBox: @unchecked Sendable {
    let image: NSImage
}

struct ThumbnailView: View {
    let url: URL
    var side: CGFloat
    var corner: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.fill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            if let hit = ThumbnailCache.shared.cached(url) { image = hit; return }
            let img = await ThumbnailCache.shared.thumbnail(for: url, side: side)
            withAnimation(.easeOut(duration: 0.18)) { image = img }
        }
    }
}

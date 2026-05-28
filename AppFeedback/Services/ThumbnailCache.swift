import Foundation
import Observation
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

@MainActor
@Observable
final class ThumbnailCache {
    private let cache = NSCache<NSString, PlatformImage>()
    private let dimension: CGFloat

    init(dimension: CGFloat = 256) {
        self.dimension = dimension
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(for url: URL) -> PlatformImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Async-friendly: returns the cached image if present, otherwise decodes
    /// the file at `path` and caches it.
    func thumbnail(for url: URL, localPath: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url.absoluteString as NSString) {
            return cached
        }
        guard let img = decode(localPath) else { return nil }
        let scaled = scale(img, to: dimension)
        cache.setObject(scaled, forKey: url.absoluteString as NSString, cost: Int(dimension * dimension * 4))
        return scaled
    }

    private func decode(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        return NSImage(contentsOf: url)
        #else
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
        #endif
    }

    private func scale(_ img: PlatformImage, to dim: CGFloat) -> PlatformImage {
        // Preserve aspect ratio: `dim` is the max edge, not a forced square. Without
        // this, portrait images get squashed into a square at cache time and look
        // wrong no matter what aspectRatio mode the display view uses.
        let src = img.size
        guard src.width > 0, src.height > 0 else { return img }
        let factor = min(dim / src.width, dim / src.height, 1)
        let newSize = CGSize(width: src.width * factor, height: src.height * factor)

        #if os(macOS)
        let out = NSImage(size: newSize)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: newSize),
                 from: NSRect(origin: .zero, size: src),
                 operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
        #else
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #endif
    }
}

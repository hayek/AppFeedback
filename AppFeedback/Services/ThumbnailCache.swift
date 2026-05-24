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
        #if os(macOS)
        let newSize = NSSize(width: dim, height: dim)
        let out = NSImage(size: newSize)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: newSize),
                 from: NSRect(origin: .zero, size: img.size),
                 operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
        #else
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim), format: format)
        return renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: CGSize(width: dim, height: dim)))
        }
        #endif
    }
}

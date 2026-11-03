import AppKit
import ImageIO

/// Small, downsampled previews so the UI never holds full-size photos.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: NSImage] = [:]

    func image(for url: URL, maxPixels: Int = 480) -> NSImage? {
        let key = url.lastPathComponent
        if let cached = cache[key] { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache[key] = image
        return image
    }

    func prune(keeping names: Set<String>) {
        cache = cache.filter { names.contains($0.key) }
    }
}

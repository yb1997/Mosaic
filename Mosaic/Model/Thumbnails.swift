import AppKit
import ImageIO

/// Small, downsampled previews so the UI never holds full-size photos.
/// Decoding runs off the main thread; the cache is read on the main thread.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    /// Decodes already running, so tiles showing the same image share one.
    private var inFlight: [String: Task<(NSImage, CGSize)?, Never>] = [:]
    /// Full-size pixel dimensions, for previewing Center scaling.
    private var pixelSizes: [String: CGSize] = [:]

    /// The original image's size in pixels, once its preview is decoded.
    func pixelSize(for url: URL) -> CGSize? {
        pixelSizes[url.lastPathComponent]
    }

    /// The preview if it's already decoded, without waiting.
    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url.lastPathComponent as NSString)
    }

    func image(for url: URL, maxPixels: Int = 480) async -> NSImage? {
        let key = url.lastPathComponent
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value?.0 }
        let task = Task.detached(priority: .userInitiated) { Self.decode(url, maxPixels: maxPixels) }
        inFlight[key] = task
        let decoded = await task.value
        inFlight[key] = nil
        guard let (image, size) = decoded else { return nil }
        cache.setObject(image, forKey: key as NSString)
        cachedNames.insert(key)
        pixelSizes[key] = size
        return image
    }

    /// File names are unique per image, so dropping unused ones is all the
    /// invalidation needed.
    func prune(keeping names: Set<String>) {
        for name in cachedNames.subtracting(names) {
            cache.removeObject(forKey: name as NSString)
        }
        cachedNames.formIntersection(names)
        pixelSizes = pixelSizes.filter { names.contains($0.key) }
    }

    /// NSCache can't list its keys.
    private var cachedNames: Set<String> = []

    private nonisolated static func decode(_ url: URL, maxPixels: Int) -> (NSImage, CGSize)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        // The thumbnail keeps the aspect ratio, and the orientation transform.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? cgImage.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? cgImage.height
        let rotated = (properties?[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let size = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return (NSImage(cgImage: cgImage, size: .zero), size)
    }
}

import AppKit
import ImageIO
import QuartzCore

/// Crossfades wallpaper changes. NSWorkspace swaps the picture instantly, so
/// the outgoing image is drawn in a click-through window just above the
/// desktop picture, the new wallpaper is set underneath, and the window fades
/// out. This only works when the outgoing picture can be redrawn exactly: one
/// of Mosaic's images (or the default still) with a scaling we recognise.
/// Anything else (aerials, Photos, dynamic wallpapers) switches instantly.
@MainActor
final class WallpaperFade {
    static let defaultsKey = "fadesWallpaperChanges"
    static let duration: TimeInterval = 0.5
    /// WallpaperAgent draws the new picture a moment after setDesktopImageURL
    /// returns; fading before then would show the old picture snap over.
    /// Measured at about 250–330 ms for a 12-megapixel JPEG on an M4 Pro.
    static let agentDelay: Duration = .milliseconds(450)

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// What a screen shows now, ready to be drawn over it.
    struct Outgoing: Sendable {
        let displayID: String
        let url: URL
        let scaling: Scaling
        let fillColor: CGColor
        /// The screen's size in pixels.
        let screenPixels: CGSize
    }

    private var overlays: [String: NSWindow] = [:]

    /// The picture on `screen`, if it can be redrawn exactly.
    static func outgoing(on screen: NSScreen, displayID: String, ours: (URL) -> Bool) -> Outgoing? {
        let workspace = NSWorkspace.shared
        guard let url = workspace.desktopImageURL(for: screen), ours(url) else { return nil }
        let options = workspace.desktopImageOptions(for: screen)
        // Fill and Fit differ only by clipping; if macOS left that out, it's ambiguous.
        let candidates = Scaling.allCases.filter { $0.matches(options) }
        guard candidates.count == 1, let scaling = candidates.first else { return nil }
        let color = (options?[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) ?? Scaling.fillColor
        let scale = screen.backingScaleFactor
        return Outgoing(displayID: displayID, url: url, scaling: scaling, fillColor: color.cgColor,
                        screenPixels: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale))
    }

    /// Decodes the outgoing images off the main thread.
    nonisolated static func decode(_ outgoing: [Outgoing]) async -> [String: CGImage] {
        await Task.detached(priority: .userInitiated) {
            var images: [String: CGImage] = [:]
            for item in outgoing {
                if let image = decodeImage(item) { images[item.displayID] = image }
            }
            return images
        }.value
    }

    private nonisolated static func decodeImage(_ item: Outgoing) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Center shows the image at actual size, so it needs every pixel; the
        // others never need more than the screen has.
        let full = max(width, height)
        let screen = Int(max(item.screenPixels.width, item.screenPixels.height).rounded(.up))
        let maxPixels = item.scaling == .center ? full : min(full, screen)
        guard maxPixels > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Puts each outgoing picture over its screen. Call before setting the new wallpapers.
    func cover(_ outgoing: [Outgoing], images: [String: CGImage], screens: [String: NSScreen]) {
        removeAll()
        for item in outgoing {
            guard let image = images[item.displayID], let screen = screens[item.displayID] else { continue }
            overlays[item.displayID] = Self.overlay(image, item: item, on: screen)
        }
        // Make sure the overlays are on screen before the wallpaper changes under them.
        CATransaction.flush()
    }

    var isCovering: Bool { !overlays.isEmpty }

    /// Fades the overlays out once WallpaperAgent has drawn the new pictures.
    func reveal() async {
        guard !overlays.isEmpty else { return }
        try? await Task.sleep(for: Self.agentDelay)
        guard !Task.isCancelled else { return }
        let windows = overlays
        overlays = [:]
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in windows.values { window.animator().alphaValue = 0 }
            } completionHandler: {
                MainActor.assumeIsolated {
                    for window in windows.values { window.close() }
                }
                continuation.resume()
            }
        }
    }

    /// Takes every overlay down at once, e.g. when the Space or screens change.
    func removeAll() {
        for window in overlays.values { window.close() }
        overlays = [:]
    }

    private static func overlay(_ image: CGImage, item: Outgoing, on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Above the desktop picture, below the desktop icons and widgets.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Only on this Space: setDesktopImageURL only changes the current one.
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        if let layer = view.layer {
            layer.masksToBounds = true
            layer.contents = image
            let shrink = item.scaling == .center
                ? Scaling.centerScale(image: CGSize(width: image.width, height: image.height), screen: item.screenPixels)
                : 1
            // A larger contentsScale draws the image smaller.
            layer.contentsScale = screen.backingScaleFactor / shrink
            layer.backgroundColor = item.fillColor
            layer.contentsGravity = switch item.scaling {
            case .fill: .resizeAspectFill
            case .fit: .resizeAspect
            case .stretch: .resize
            case .center: .center
            }
        }
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }
}

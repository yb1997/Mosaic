import AppKit
import AVFoundation
import ImageIO
import IOKit.ps

/// Plays video wallpapers. macOS can't use a video as the desktop picture, so
/// each screen with one gets a click-through window just above the picture
/// (the fade overlay's level, under icons, widgets and windows) on every
/// Space, playing the video muted on a loop. The engine still sets the video's
/// still frame as the real wallpaper underneath, for Mission Control, the lock
/// screen and when Mosaic isn't running. Tested in Spikes/videospike.swift.
@MainActor
final class VideoWallpapers {
    private var screens: [String: VideoScreen] = [:]
    /// Windows fading out after their video was removed.
    private var leaving: Set<VideoScreen> = []

    /// False pauses every video (locked, asleep, Low Power Mode, on battery
    /// when asked to, or paused from the panel). Each video also pauses on
    /// its own while nothing of it is visible, such as under a full-screen app.
    var allowsPlayback = true {
        didSet {
            guard allowsPlayback != oldValue else { return }
            screens.values.forEach { $0.updatePlayback(allowed: allowsPlayback) }
        }
    }

    func isShowing(on displayID: String) -> Bool {
        screens[displayID] != nil
    }

    /// Whether `show` would change anything on this screen.
    func needsChange(on display: Display, video: URL?, scaling: Scaling) -> Bool {
        guard let current = screens[display.id] else { return video != nil }
        return current.url != video || current.scaling != scaling || current.frame != display.screen.frame
    }

    /// Shows `video` on a screen (or takes it down when nil). With `fade`, a
    /// new video fades in over what's there, and one taken down fades out
    /// after `delay`, once the picture underneath has changed.
    func show(_ video: URL?, scaling: Scaling, on display: Display, fade: Bool, delay: Duration = .zero) {
        let current = screens[display.id]
        guard let video else {
            if let current { remove(current, displayID: display.id, fade: fade, delay: delay) }
            return
        }
        if let current, current.url == video {
            current.place(on: display.screen, scaling: scaling)
            return
        }
        let screen = VideoScreen(url: video, screen: display.screen, scaling: scaling)
        screens[display.id] = screen
        screen.updatePlayback(allowed: allowsPlayback)
        screen.appear(fade: fade) { [weak self] in
            // The new video covers the old one; take the old one down underneath.
            if let current { self?.close(current) }
        }
    }

    /// Takes down videos on screens that are no longer connected.
    func keepOnly(_ displayIDs: Set<String>) {
        for (id, screen) in screens where !displayIDs.contains(id) {
            remove(screen, displayID: id, fade: false, delay: .zero)
        }
    }

    func removeAll() {
        for (id, screen) in screens { remove(screen, displayID: id, fade: false, delay: .zero) }
    }

    private func remove(_ screen: VideoScreen, displayID: String, fade: Bool, delay: Duration) {
        screens[displayID] = nil
        guard fade else { return close(screen) }
        leaving.insert(screen)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            screen.disappear { self?.close(screen) }
        }
    }

    private func close(_ screen: VideoScreen) {
        leaving.remove(screen)
        screen.close()
    }

    // MARK: Power

    /// Whether the Mac is running on its battery.
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return type as String == kIOPSBatteryPowerValue
    }

    static let powerSourceDidChange = Notification.Name("in.ybear.Mosaic.powerSourceDidChange")
    private static var powerSource: CFRunLoopSource?

    /// Posts `powerSourceDidChange` when the Mac switches between battery and power adapter.
    static func watchPowerSource() {
        guard powerSource == nil,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  NotificationCenter.default.post(name: VideoWallpapers.powerSourceDidChange, object: nil)
              }, nil)?.takeRetainedValue()
        else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}

/// One screen's video window.
@MainActor
private final class VideoScreen: NSObject, NSWindowDelegate {
    let url: URL
    private(set) var scaling: Scaling
    private(set) var frame: NSRect
    private let window: NSWindow
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer: AVPlayerLayer
    private var isAllowed = true
    /// The video's upright size in pixels, read from its still frame, for Center.
    private let videoPixels: CGSize?

    init(url: URL, screen: NSScreen, scaling: Scaling) {
        self.url = url
        self.scaling = scaling
        frame = screen.frame
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        playerLayer = AVPlayerLayer(player: player)
        videoPixels = Self.pixelSize(ofStillFor: url)
        super.init()

        // Above the desktop picture, below the desktop icons and widgets.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.isOpaque = true
        window.backgroundColor = Scaling.fillColor
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // On every Space, so a Space switch slides the video along.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = Scaling.fillColor.cgColor
        view.layer?.masksToBounds = true
        view.layer?.addSublayer(playerLayer)
        window.contentView = view

        player.isMuted = true
        // Defaults to true on macOS, which would keep the display awake forever.
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        place(on: screen, scaling: scaling)
    }

    func place(on screen: NSScreen, scaling: Scaling) {
        self.scaling = scaling
        frame = screen.frame
        window.setFrame(screen.frame, display: false)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch scaling {
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = bounds
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = bounds
        case .stretch:
            playerLayer.videoGravity = .resize
            playerLayer.frame = bounds
        case .center:
            // Actual size, as macOS shows a centred picture.
            playerLayer.videoGravity = .resizeAspect
            if let pixels = videoPixels {
                let scale = screen.backingScaleFactor
                let screenPixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let shrink = Scaling.centerScale(image: pixels, screen: screenPixels)
                let size = CGSize(width: pixels.width * shrink / scale, height: pixels.height * shrink / scale)
                playerLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                           width: size.width, height: size.height)
            } else {
                playerLayer.frame = bounds
            }
        }
        CATransaction.commit()
    }

    func appear(fade: Bool, completion: @escaping @MainActor () -> Void) {
        window.alphaValue = fade ? 0 : 1
        window.orderFrontRegardless()
        // A window that lands already hidden (say, under a full-screen app)
        // may never report an occlusion change, so check now and once
        // WindowServer has worked it out.
        updatePlayback(allowed: isAllowed)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePlayback(allowed: self.isAllowed)
        }
        guard fade else { return completion() }
        // Fading in before the first frame is drawn would dim the screen to black.
        Task { [weak self] in
            for _ in 0..<50 {
                guard let self, !self.playerLayer.isReadyForDisplay else { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            self?.animate(to: 1, completion: completion)
        }
    }

    func disappear(completion: @escaping @MainActor () -> Void) {
        animate(to: 0, completion: completion)
    }

    private func animate(to alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = WallpaperFade.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }

    func updatePlayback(allowed: Bool) {
        isAllowed = allowed
        let visible = window.occlusionState.contains(.visible) || !window.isVisible
        let plays = allowed && visible
        guard plays != (player.rate != 0) else { return }
        if plays {
            player.play()
        } else {
            player.pause()
        }
        Log.engine.info("\(plays ? "Playing" : "Paused", privacy: .public) \(self.url.lastPathComponent.prefix(12), privacy: .public) on \(self.window.screen?.localizedName ?? "?", privacy: .public)\(allowed ? "" : " (not allowed now)", privacy: .public)")
    }

    func close() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        window.close()
    }

    nonisolated func windowDidChangeOcclusionState(_ notification: Notification) {
        MainActor.assumeIsolated { updatePlayback(allowed: isAllowed) }
    }

    /// Stored videos keep their still frame next to them (VideoFile).
    private static func pixelSize(ofStillFor video: URL) -> CGSize? {
        let still = video.deletingPathExtension().appendingPathExtension("heic")
        guard let source = CGImageSourceCreateWithURL(still as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

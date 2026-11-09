import AppKit

/// Puts the right image on each screen. macOS shows the desktop wallpaper on
/// the lock screen, so a separate lock image is done by swapping the desktop
/// while the screen is locked (see Spikes/README.md). A lock screen video
/// instead becomes the screen's system wallpaper for good, as a custom aerial,
/// with Mosaic's window showing the desktop on top (LockScreenVideos).
/// Everything is driven by notifications; nothing polls.
@MainActor
final class WallpaperEngine {
    private let store: WallpaperStore
    private var isLocked = false
    /// macOS's wallpaper settings from just before a lock swap that covered a
    /// screen without a desktop image of ours. NSWorkspace can't set Photos
    /// pictures or aerials back, so unlocking restores this instead.
    private var settingsBeforeLock: Data?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var screenChange: Task<Void, Never>?
    /// Screens whose desktop image was cleared with ×. They show the macOS
    /// default until they get an image again. Screens that are only empty
    /// (say, left out of a profile) keep whatever wallpaper they have.
    private var clearedDisplays: Set<String> = []
    private let fade = WallpaperFade()
    private var fadeTask: Task<Void, Never>?
    private let videos = VideoWallpapers()
    private let lockVideos: LockScreenVideos
    private var isAsleep = false

    /// A still of the macOS default wallpaper (the default itself is an
    /// aerial, which NSWorkspace can't set).
    private static let defaultWallpaper: URL? = [
        "/System/Library/CoreServices/DefaultDesktop.heic",
        "/System/Library/CoreServices/DefaultBackground.jpg",
    ]
    .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    .first { FileManager.default.fileExists(atPath: $0.path) }

    init(store: WallpaperStore) {
        self.store = store
        lockVideos = LockScreenVideos(imagesDirectory: store.imagesDirectory)
        #if DEBUG
        // `-keepWallpapers YES` never touches the real wallpapers, e.g. for screenshots with sample images.
        if UserDefaults.standard.bool(forKey: "keepWallpapers") { return }
        #endif
        // Changes made in Mosaic fade; wake, screen changes and locking stay instant.
        store.onChange = { [weak self] in self?.applyChange() }
        store.onDesktopCleared = { [weak self] in self?.clearedDisplays.insert($0) }
        store.onPlaybackChange = { [weak self] in self?.updatePlayback() }
        lockVideos.onChange = { [weak self] in self?.apply() }
        lockVideos.onFailure = { [weak store] in store?.reportError($0) }
        lockVideos.onFailedChange = { [weak store] in store?.failedLockVideos = $0 }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.setLocked(true) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.setLocked(false) }

        let workspace = NSWorkspace.shared.notificationCenter
        // setDesktopImageURL only changes the current Space, so cover each Space
        // as it is shown. A Space that missed a change still shows the old
        // picture when it slides in, so fade that too instead of snapping;
        // Spaces that are already up to date have nothing to change.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification.rawValue) { $0.applyChange() }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { engine in
            engine.setAsleep(false)
            // Something may have changed macOS's settings or aerials meanwhile.
            engine.lockVideos.readActive()
            engine.apply()
        }
        // Videos pause while the Mac or its screens sleep, in Low Power Mode,
        // and on battery when Settings asks for that.
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.setAsleep(true) }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.setAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.setAsleep(false) }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange.rawValue) { $0.updatePlayback() }
        observe(.default, VideoWallpapers.powerSourceDidChange.rawValue) { $0.updatePlayback() }
        observe(.default, UserDefaults.didChangeNotification.rawValue) { $0.updatePlayback() }
        VideoWallpapers.watchPowerSource()
        // This arrives several times in a row when a monitor is plugged in or
        // wakes, so act once things have settled.
        observe(.default, NSApplication.didChangeScreenParametersNotification.rawValue) { engine in
            engine.cancelFade()
            engine.screenChange?.cancel()
            engine.screenChange = Task { [weak engine] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let engine else { return }
                engine.store.refreshDisplays()
                engine.apply()
            }
        }
        // Battery and Low Power Mode may already apply; no notification says so.
        updatePlayback()
        apply()
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ handler: @escaping @MainActor (WallpaperEngine) -> Void) {
        let token = center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
        observers.append((center, token))
    }

    private func setAsleep(_ asleep: Bool) {
        isAsleep = asleep
        updatePlayback()
    }

    /// Whether videos may play at all right now (each also pauses while hidden).
    private func updatePlayback() {
        let pausesOnBattery = UserDefaults.standard.bool(forKey: VideoFormat.pausesOnBatteryKey)
        videos.allowsPlayback = !store.videosPaused && !isLocked && !isAsleep
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !(pausesOnBattery && VideoWallpapers.isOnBattery)
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        updatePlayback()
        if locked {
            let coversForeignWallpaper = store.displays.contains {
                let wallpapers = store.wallpapers(for: $0)
                return wallpapers.effectiveLock != nil && wallpapers.desktop == nil && !lockVideos.isActive(on: $0.id)
            }
            if coversForeignWallpaper {
                settingsBeforeLock = SystemWallpaperStore.snapshot()
            }
            apply()
        } else if let saved = settingsBeforeLock {
            // The snapshot was taken after our desktop images were set, so it
            // brings those back too.
            settingsBeforeLock = nil
            SystemWallpaperStore.restore(saved)
        } else {
            apply()
        }
    }

    /// One screen whose wallpaper needs setting.
    private struct Change {
        let display: Display
        let target: URL
        let scaling: Scaling
    }

    /// Sets every screen's wallpaper at once, with no fade.
    func apply() {
        cancelFade()
        pendingChanges().forEach(set)
        showVideos(fade: false)
        updateLockVideos()
    }

    /// Starts or stops lock screen videos to match the choices. Never while
    /// locked: that restarts WallpaperAgent, which would race the lock.
    private func updateLockVideos() {
        guard !isLocked else { return }
        var wanted: [String: LockScreenVideos.Wanted] = [:]
        for display in store.displays {
            let wallpapers = store.wallpapers(for: display)
            guard let file = wallpapers.lockVideo else { continue }
            let scaling = wallpapers.effectiveLockScaling
            wanted[display.id] = .init(assetID: AerialCatalog.assetID(for: file, scaling: scaling), file: file, scaling: scaling)
        }
        lockVideos.update(wanted: wanted, connected: Set(store.displays.map(\.id)), picture: { [store, clearedDisplays] id in
            // A screen that's only empty gets back whatever it had before.
            store.pictureURL(store.screens[id]?.desktop) ?? (clearedDisplays.contains(id) ? Self.defaultWallpaper : nil)
        }, fallbackPicture: Self.defaultWallpaper, lockPicture: { [store] id in
            let wallpapers = store.screens[id]
            return store.pictureURL(wallpapers?.effectiveLock ?? wallpapers?.desktop)
        })
    }

    /// Puts each screen's desktop video in its window, or takes it down.
    /// With `fade`, a removed video fades out once the picture under it has changed.
    private func showVideos(fade: Bool) {
        videos.keepOnly(Set(store.displays.map(\.id)))
        for (display, video, scaling) in desiredVideos() {
            videos.show(video, scaling: scaling, on: display, fade: fade, delay: WallpaperFade.agentDelay)
        }
    }

    /// Each connected screen's desktop video, or nil where its desktop isn't
    /// one. A screen playing a lock screen video gets its desktop picture in
    /// the window too, as its system wallpaper is the video's aerial. With no
    /// desktop of its own it shows the default if it was cleared, or the
    /// picture it had before. A Photos picture or aerial can't be drawn, so
    /// then the aerial's still frame stays until the video stops.
    private func desiredVideos() -> [(Display, URL?, Scaling)] {
        store.displays.map { display in
            let wallpapers = store.wallpapers(for: display)
            let isActive = lockVideos.isActive(on: display.id)
            if wallpapers.desktop == nil, isActive {
                let cover = clearedDisplays.contains(display.id) ? Self.defaultWallpaper : lockVideos.savedPicture(on: display.id)
                return (display, cover, .fill)
            }
            let video = VideoFile.isVideo(wallpapers.desktop) || isActive ? store.imageURL(wallpapers.desktop) : nil
            return (display, video, wallpapers.desktopScaling)
        }
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fade.removeAll()
    }

    /// A change made in Mosaic: fades it in when it can.
    private func applyChange() {
        guard !isLocked, WallpaperFade.isEnabled else { return apply() }
        cancelFade()
        fadeTask = Task { [weak self] in await self?.applyWithFade() }
    }

    private func applyWithFade() async {
        // A change to the lock screen alone changes nothing on the desktop.
        updateLockVideos()
        let changes = pendingChanges()
        let videoChanges = desiredVideos().contains { videos.needsChange(on: $0.0, video: $0.1, scaling: $0.2) }
        guard !changes.isEmpty || videoChanges else { return }
        // A screen showing a video is already covered by it.
        let outgoing = changes.filter { !videos.isShowing(on: $0.display.id) }.compactMap {
            WallpaperFade.outgoing(on: $0.display.screen, displayID: $0.display.id, ours: isOurs)
        }
        let images = outgoing.isEmpty ? [:] : await WallpaperFade.decode(outgoing)
        // Something else (a Space switch, another change) took over meanwhile.
        guard !Task.isCancelled else { return }
        let screens = Dictionary(changes.map { ($0.display.id, $0.display.screen) }) { first, _ in first }
        fade.cover(outgoing, images: images, screens: screens)
        // Work out the changes again: the store may have moved on while decoding.
        pendingChanges().forEach(set)
        showVideos(fade: true)
        await fade.reveal()
    }

    /// Whether this is a picture Mosaic set, so it can be redrawn exactly.
    private func isOurs(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let images = store.imagesDirectory.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(images) || path == Self.defaultWallpaper?.path
    }

    private func pendingChanges() -> [Change] {
        store.displays.compactMap { display in
            let wallpapers = store.wallpapers(for: display)
            let screen = display.screen
            if wallpapers.desktop != nil { clearedDisplays.remove(display.id) }
            // Its system wallpaper is a lock screen video; setting a picture
            // would replace it (on this Space), and NSWorkspace can't read
            // an aerial back to compare.
            if lockVideos.isActive(on: display.id) { return nil }
            // A video's still frame is the real wallpaper under its window.
            let desktop = store.pictureURL(wallpapers.desktop)
                ?? (clearedDisplays.contains(display.id) ? Self.defaultWallpaper : nil)
            let lock = isLocked ? store.pictureURL(wallpapers.effectiveLock) : nil
            guard let target = lock ?? desktop else { return nil }
            // The macOS default is always shown filling the screen.
            let scaling = lock != nil ? wallpapers.lockScaling
                : wallpapers.desktop != nil ? wallpapers.desktopScaling : .fill
            let workspace = NSWorkspace.shared
            guard target != workspace.desktopImageURL(for: screen)
                    || !scaling.matches(workspace.desktopImageOptions(for: screen))
            else { return nil }
            return Change(display: display, target: target, scaling: scaling)
        }
    }

    private func set(_ change: Change) {
        do {
            try NSWorkspace.shared.setDesktopImageURL(change.target, for: change.display.screen, options: change.scaling.options)
        } catch {
            Log.engine.error("Could not set \(change.target.lastPathComponent, privacy: .public) on \(change.display.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

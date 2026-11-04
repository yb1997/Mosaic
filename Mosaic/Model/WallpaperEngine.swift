import AppKit

/// Puts the right image on each screen. macOS shows the desktop wallpaper on
/// the lock screen, so a separate lock image is done by swapping the desktop
/// while the screen is locked (see Spikes/README.md). Everything is driven by
/// notifications; nothing polls.
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

    private let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ]

    init(store: WallpaperStore) {
        self.store = store
        #if DEBUG
        // `-keepWallpapers YES` never touches the real wallpapers, e.g. for screenshots with sample images.
        if UserDefaults.standard.bool(forKey: "keepWallpapers") { return }
        #endif
        store.onChange = { [weak self] in self?.apply() }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.setLocked(true) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.setLocked(false) }

        let workspace = NSWorkspace.shared.notificationCenter
        // setDesktopImageURL only changes the current Space, so cover each Space as it is shown.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification.rawValue) { $0.apply() }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.apply() }
        // This arrives several times in a row when a monitor is plugged in or
        // wakes, so act once things have settled.
        observe(.default, NSApplication.didChangeScreenParametersNotification.rawValue) { engine in
            engine.screenChange?.cancel()
            engine.screenChange = Task { [weak engine] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let engine else { return }
                engine.store.refreshDisplays()
                engine.apply()
            }
        }
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

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        if locked {
            let coversForeignWallpaper = store.displays.contains {
                let wallpapers = store.wallpapers(for: $0)
                return wallpapers.effectiveLock != nil && wallpapers.desktop == nil
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

    func apply() {
        for display in store.displays {
            let wallpapers = store.wallpapers(for: display)
            let screen = display.screen
            let current = NSWorkspace.shared.desktopImageURL(for: screen)
            let target = store.imageURL(isLocked ? (wallpapers.effectiveLock ?? wallpapers.desktop) : wallpapers.desktop)
            guard let target, target != current else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(target, for: screen, options: options)
            } catch {
                NSLog("Mosaic: could not set \(target.lastPathComponent) on \(display.name): \(error)")
            }
        }
    }
}

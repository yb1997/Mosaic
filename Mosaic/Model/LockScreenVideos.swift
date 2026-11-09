import Foundation

/// Makes screens' lock screens play videos (docs/LOCK_SCREEN_VIDEO.md).
/// macOS only animates aerial wallpapers there, so a screen whose lock screen
/// plays a video gets that video as a custom aerial for its system wallpaper.
/// On the desktop an aerial is a still frame; Mosaic's own window covers it
/// with the desktop picture or video.
///
/// Changing a screen's system wallpaper to or from an aerial means rewriting
/// macOS's settings file and restarting WallpaperAgent, which flashes every
/// screen, so `update` only does that when something actually changed, and
/// never while the screen is locked.
@MainActor
final class LockScreenVideos {
    /// What a screen's lock screen should play.
    struct Wanted: Equatable {
        let assetID: String
        let file: VideoFile
        let scaling: Scaling
    }

    /// Screens whose system wallpaper is one of Mosaic's aerials, by display
    /// ID, with the asset each shows.
    private(set) var active: [String: String] = [:]
    /// Assets whose lock copy and catalog entry are known to be in place.
    private var registered: Set<String> = []
    private var preparing: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Assets that couldn't be made, so they aren't retried on every change.
    private var failed: Set<String> = [] {
        didSet { if failed != oldValue { onFailedChange(failed) } }
    }
    /// Settings writes made for each screen since its wanted video last
    /// changed, so one that doesn't stick isn't repeated (and the agent
    /// restarted) on every Space switch, while going back to an earlier
    /// video still writes.
    private var written: Set<String> = []
    /// Each screen's wanted asset (nil for a picture) at the last update.
    private var lastWanted: [String: String?] = [:]
    /// Something changed since the catalog was last tidied. Tidying reads the
    /// catalogs, so it isn't done on every Space switch.
    private var needsCleanUp = true
    /// Mosaic's assets in the catalogs at the last `readActive`.
    private var catalogAssets: Set<String> = []

    /// Called after a screen starts or stops showing a lock video, so the
    /// engine puts the right pictures and windows up.
    var onChange: () -> Void = {}
    /// Called with a message when a lock video can't be made.
    var onFailure: (String) -> Void = { _ in }
    /// Called with the assets that couldn't be made, whenever they change.
    var onFailedChange: (Set<String>) -> Void = { _ in }

    private let imagesDirectory: URL

    init(imagesDirectory: URL) {
        self.imagesDirectory = imagesDirectory
        readActive()
    }

    func isActive(on displayID: String) -> Bool {
        active[displayID] != nil
    }

    /// The picture file a screen showed before its lock video, if it was one.
    func savedPicture(on displayID: String) -> URL? {
        SystemWallpaperStore.savedPicture(Self.savedWallpapers[displayID]).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
    }

    /// Reads which screens show one of Mosaic's aerials from macOS's
    /// settings, and forgets what was checked. On launch and wake, when
    /// something else (an update, Native Aerials, System Settings) may have
    /// changed the settings or the catalog.
    func readActive() {
        written = []
        lastWanted = [:]
        registered = []
        failed = []
        needsCleanUp = true
        let ours = AerialCatalog.ourAssetIDs()
        catalogAssets = ours
        guard let store = SystemWallpaperStore.load(), let displays = store["Displays"] as? NSDictionary else {
            active = [:]
            return
        }
        active = [:]
        for case let id as String in displays.allKeys {
            if let asset = SystemWallpaperStore.aerialAsset(on: id, in: store), ours.contains(asset) {
                active[id] = asset
            }
        }
    }

    /// Brings macOS's wallpaper settings in line with `wanted` for the
    /// connected screens. `picture` is what a screen's system wallpaper goes
    /// back to when it stops playing a video, or nil to put back what it had
    /// before, or `fallbackPicture` if that's unknown. `lockPicture` is what
    /// a screen without a video shows when locked.
    func update(wanted: [String: Wanted], connected: Set<String>, picture: (String) -> URL?, fallbackPicture: URL?, lockPicture: (String) -> URL?) {
        for display in connected where lastWanted[display] != .some(wanted[display]?.assetID) {
            lastWanted[display] = .some(wanted[display]?.assetID)
            written = written.filter { !$0.hasPrefix("\(display)|") }
            // Choosing a video again is a reason to try again.
            if let asset = wanted[display]?.assetID { failed.remove(asset) }
        }
        // Nothing to start, stop or put back: skip reading macOS's settings, which
        // would otherwise happen on every Space switch. Launch and wake still
        // look (needsCleanUp), for anything changed behind Mosaic's back.
        if wanted.isEmpty, active.isEmpty, preparing.isEmpty, !needsCleanUp, Self.savedScreenSavers.isEmpty { return }
        // An encode for a video no screen wants any more (replaced, cleared, screen gone) is stopped.
        let wantedAssets = Set(wanted.values.map(\.assetID))
        for (asset, entry) in preparing where !wantedAssets.contains(asset) {
            entry.task.cancel()
            preparing[asset] = nil
        }
        // What macOS actually shows, not what was last written: something
        // else (the agent, System Settings, a restore) may have changed it.
        let current = SystemWallpaperStore.load()
        let known = Set(active.values).union(registered).union(wanted.values.map(\.assetID)).union(preparing.keys)
        if let current {
            for display in connected {
                active[display] = SystemWallpaperStore.aerialAsset(on: display, in: current).flatMap { known.contains($0) ? $0 : nil }
            }
        }
        for item in Set(wanted.values.map { WantedAsset($0) }) where !registered.contains(item.wanted.assetID) {
            prepare(item.wanted)
        }
        // The screen saver has to show the video too: a Mac that locks after
        // sitting idle starts the screen saver first, and the lock screen
        // shows that, not the wallpaper.
        var toSet: [String: String] = [:]
        for (display, item) in wanted where registered.contains(item.assetID) {
            let saverShows = current.map { SystemWallpaperStore.screenSaverShows(item.assetID, on: display, in: $0) } ?? true
            if active[display] != item.assetID || !saverShows { toSet[display] = item.assetID }
        }
        // A screen waiting for a new video keeps the old one until it's ready.
        let toClear = active.keys.filter { connected.contains($0) && wanted[$0] == nil }
        // While any screen plays a video, the others show their lock picture
        // on an idle lock, not whatever screen saver they had. Otherwise
        // Mosaic leaves the screen savers to macOS.
        var saved = Self.savedScreenSavers
        var saverPictures: [String: URL] = [:]
        if !wanted.isEmpty {
            for display in connected where wanted[display] == nil { saverPictures[display] = lockPicture(display) }
        }
        let toSetSaver = saverPictures.filter { display, image in
            current.map { !SystemWallpaperStore.screenSaverShows(image: image, on: display, in: $0) } ?? false
        }
        // Screens whose wallpaper was changed elsewhere while the screen saver
        // still shows Mosaic's video or picture: only the screen saver goes
        // back. One with nothing saved may still name a Mosaic video.
        let mine = known.union(catalogAssets)
        let toRestoreSaver = connected.filter { display in
            guard wanted[display] == nil, active[display] == nil, saverPictures[display] == nil else { return false }
            return saved[display] != nil || (current.map { SystemWallpaperStore.screenSaverShowsAny(of: mine, on: display, in: $0) } ?? false)
        }
        // With the entry count, so a new Space is a reason to write again.
        let attempts = toSet.map { item in
            "\(item.key)|\(item.value)|\(current.map { SystemWallpaperStore.entryCount(on: item.key, in: $0) } ?? 0)"
        } + toClear.map { "\($0)|image" } + toRestoreSaver.map { "\($0)|saver" }
            + toSetSaver.map { "\($0.key)|saver|\($0.value.lastPathComponent)" }
        let fresh = attempts.filter { !written.contains($0) }
        guard !fresh.isEmpty, let store = current else {
            if needsCleanUp { cleanUp(wanted: wanted) }
            return
        }
        // A screen saver can go back to an earlier picture, or be set again
        // after being restored, so only its latest write counts.
        let saverDisplays = toRestoreSaver.union(toSetSaver.keys)
        written = written.filter { key in !saverDisplays.contains { key.hasPrefix("\($0)|saver") } }
        written.formUnion(attempts)
        let ours = known.union(AerialCatalog.ourAssetIDs())
        var changed: [String: String?] = [:]
        var restoredSavers: [String] = []
        var picturedSavers: [String] = []
        var savedWallpapers = Self.savedWallpapers
        for (display, asset) in toSet {
            let before = SystemWallpaperStore.screenSavers(on: display, in: store, ignoring: ours, picturesIn: imagesDirectory)
            let wallpaperBefore = SystemWallpaperStore.wallpapers(on: display, in: store, ignoring: ours, picturesIn: imagesDirectory)
            guard SystemWallpaperStore.setAerial(asset, on: display, in: store) else { continue }
            saved[display] = SystemWallpaperStore.mergeSaved(saved[display], before)
            savedWallpapers[display] = SystemWallpaperStore.mergeSaved(savedWallpapers[display], wallpaperBefore)
            changed[display] = asset
        }
        for display in toClear {
            let wentBack = if let image = picture(display) {
                SystemWallpaperStore.setImage(image, on: display, in: store)
            } else if SystemWallpaperStore.restoreWallpapers(savedWallpapers[display], replacing: ours, picturesIn: imagesDirectory, on: display, in: store) {
                true
            } else if let fallbackPicture {
                SystemWallpaperStore.setImage(fallbackPicture, on: display, in: store)
            } else {
                false
            }
            if wentBack {
                savedWallpapers[display] = nil
                if saverPictures[display] == nil {
                    SystemWallpaperStore.restoreScreenSavers(saved[display], replacing: ours, picturesIn: imagesDirectory, on: display, in: store)
                    saved[display] = nil
                }
                changed[display] = .some(nil)
            }
        }
        for display in toRestoreSaver {
            if SystemWallpaperStore.restoreScreenSavers(saved[display], replacing: ours, picturesIn: imagesDirectory, on: display, in: store) {
                restoredSavers.append(display)
            }
            saved[display] = nil
        }
        for (display, image) in toSetSaver {
            let before = SystemWallpaperStore.screenSavers(on: display, in: store, ignoring: ours, picturesIn: imagesDirectory)
            guard SystemWallpaperStore.setScreenSaver(image: image, on: display, in: store) else { continue }
            saved[display] = SystemWallpaperStore.mergeSaved(saved[display], before)
            picturedSavers.append(display)
        }
        guard !changed.isEmpty || !restoredSavers.isEmpty || !picturedSavers.isEmpty, SystemWallpaperStore.write(store) else { return }
        // Only once the settings are written: if the write fails, the saved
        // choices must stay, or the originals could never be put back.
        Self.savedScreenSavers = saved
        Self.savedWallpapers = savedWallpapers
        for (display, asset) in changed { active[display] = asset }
        let summary = (changed.map { "\($0.key.prefix(8)) → \($0.value.map { String($0.prefix(8)) } ?? "picture")" }
            + restoredSavers.map { "\($0.prefix(8)) → screen saver back" }
            + picturedSavers.map { "\($0.prefix(8)) → screen saver shows its picture" }).sorted().joined(separator: ", ")
        Log.engine.info("Lock screen videos: \(summary, privacy: .public); restarted WallpaperAgent")
        cleanUp(wanted: wanted)
        DispatchQueue.main.async { [weak self] in self?.onChange() }
    }

    /// Each screen's screen saver choices from before it showed a lock video
    /// (from `SystemWallpaperStore.screenSavers`), kept across launches so
    /// they go back when the video stops, even after a restart.
    private static let savedScreenSaversKey = "lockVideoScreenSavers"
    private static var savedScreenSavers: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: savedScreenSaversKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: savedScreenSaversKey) }
    }

    /// Each screen's wallpaper from before it showed a lock video, kept the
    /// same way, so a Photos picture or aerial isn't lost.
    private static let savedWallpapersKey = "lockVideoWallpapers"
    private static var savedWallpapers: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: savedWallpapersKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: savedWallpapersKey) }
    }

    /// Removes Mosaic's aerials that no screen shows or waits for, and mends
    /// a catalog an earlier version left unreadable.
    private func cleanUp(wanted: [String: Wanted]) {
        needsCleanUp = false
        let keep = Set(active.values).union(wanted.values.map(\.assetID)).union(preparing.keys)
        registered.formIntersection(keep)
        Task.detached(priority: .utility) {
            do {
                if try AerialCatalog.unregister(keeping: keep) {
                    Log.engine.info("Changed macOS's aerial list; restarting WallpaperAgent")
                    SystemWallpaperStore.restartAgent()
                }
            } catch {
                Log.engine.error("Could not remove old lock screen videos: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Makes the lock copy of the video if needed and lists it in the
    /// catalog, in the background, then updates again.
    private func prepare(_ wanted: Wanted) {
        let asset = wanted.assetID
        guard preparing[asset] == nil, !failed.contains(asset) else { return }
        let video = imagesDirectory.appendingPathComponent(wanted.file.fileName)
        let still = imagesDirectory.appendingPathComponent(wanted.file.stillName)
        let aerial = imagesDirectory.appendingPathComponent(wanted.file.aerialName)
        let scaling = wanted.scaling
        let id = UUID()
        let task = Task { [weak self] in
            do {
                let work = Task.detached(priority: .utility) { () -> Bool in
                    var claimed = try AerialCatalog.claimOverride()
                    if !AerialCatalog.isRegistered(asset) {
                        try await Self.makeAerial(from: video, at: aerial)
                        // Claims again: cleanup may have released it during the encode.
                        if try AerialCatalog.register(asset, video: aerial, still: still, scaling: scaling) { claimed = true }
                    }
                    return claimed
                }
                // Detached work isn't cancelled with this task, so pass that on.
                let claimed = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                // A screen about to get the video restarts the agent anyway.
                if claimed, self?.active.values.contains(asset) == true {
                    Log.engine.info("Set Mosaic's aerial list; restarting WallpaperAgent")
                    SystemWallpaperStore.restartAgent()
                }
                self?.registered.insert(asset)
                Log.engine.info("Lock screen video \(asset, privacy: .public) is ready")
            } catch is CancellationError {
                Log.engine.info("Lock screen video \(asset, privacy: .public) is no longer wanted; stopped")
            } catch {
                self?.failed.insert(asset)
                Log.engine.error("Could not make lock screen video \(asset, privacy: .public): \(String(describing: error), privacy: .public)")
                self?.onFailure("The lock screen video couldn't be made: \(error.localizedDescription)")
            }
            if self?.preparing[asset]?.id == id { self?.preparing[asset] = nil }
            self?.needsCleanUp = true
            self?.onChange()
        }
        preparing[asset] = (id, task)
    }

    /// Encodes the lock copy next to the stored video, unless it's there.
    /// Written elsewhere first, so a half-written file never has its name.
    nonisolated private static func makeAerial(from video: URL, at aerial: URL) async throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: aerial.path) else { return }
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("Mosaic-aerial-\(UUID().uuidString).mov")
        defer { try? fileManager.removeItem(at: temporary) }
        try await VideoEncoder.encodeAerial(video, to: temporary) { _ in }
        if !fileManager.fileExists(atPath: aerial.path) {
            try fileManager.moveItem(at: temporary, to: aerial)
        }
    }

    /// Wanted, compared by asset only, so a video on two screens is made once.
    private struct WantedAsset: Hashable {
        let wanted: Wanted
        init(_ wanted: Wanted) { self.wanted = wanted }
        static func == (a: Self, b: Self) -> Bool { a.wanted.assetID == b.wanted.assetID }
        func hash(into hasher: inout Hasher) { hasher.combine(wanted.assetID) }
    }
}

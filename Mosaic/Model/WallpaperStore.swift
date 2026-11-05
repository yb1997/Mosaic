import AppKit
import CryptoKit
import Observation
import UniformTypeIdentifiers

enum Slot: String, Codable, CaseIterable {
    case desktop, lock

    var title: String { self == .desktop ? "Desktop" : "Lock Screen" }
}

/// The images picked for one display, as file names inside `imagesDirectory`.
struct ScreenWallpapers: Codable, Equatable {
    var desktop: String?
    var lock: String?
    /// Show the desktop image on the lock screen. The lock image is kept so
    /// turning this off brings it back.
    var lockSameAsDesktop = false
    /// How each slot's image is fitted to the screen. Kept with the slot, not
    /// the image, so a new image keeps the slot's choice.
    var desktopScaling = Scaling.fill
    var lockScaling = Scaling.fill

    /// The lock image actually in use.
    var effectiveLock: String? { lockSameAsDesktop ? nil : lock }

    /// The scaling of the image the lock screen shows, which is the desktop's
    /// when it has no image of its own.
    var effectiveLockScaling: Scaling { effectiveLock == nil ? desktopScaling : lockScaling }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktop = try container.decodeIfPresent(String.self, forKey: .desktop)
        lock = try container.decodeIfPresent(String.self, forKey: .lock)
        lockSameAsDesktop = try container.decodeIfPresent(Bool.self, forKey: .lockSameAsDesktop) ?? false
        // An unknown value (from a newer version) falls back to the default.
        desktopScaling = (try? container.decodeIfPresent(Scaling.self, forKey: .desktopScaling)) ?? .fill
        lockScaling = (try? container.decodeIfPresent(Scaling.self, forKey: .lockScaling)) ?? .fill
    }

    func scaling(_ slot: Slot) -> Scaling {
        slot == .desktop ? desktopScaling : lockScaling
    }

    mutating func setScaling(_ scaling: Scaling, for slot: Slot) {
        if slot == .desktop { desktopScaling = scaling } else { lockScaling = scaling }
    }

    subscript(slot: Slot) -> String? {
        get { slot == .desktop ? desktop : lock }
        set { if slot == .desktop { desktop = newValue } else { lock = newValue } }
    }
}

/// A named snapshot of every screen's choices, to switch between setups.
/// Screens that aren't connected keep their entries.
struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var screens: [String: ScreenWallpapers]

    init(name: String, screens: [String: ScreenWallpapers]) {
        id = UUID()
        self.name = name
        self.screens = screens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        screens = try container.decodeIfPresent([String: ScreenWallpapers].self, forKey: .screens) ?? [:]
    }
}

/// Picked images and where they live. Images are copied into the app's own
/// folder so they keep working if the originals move, and so WallpaperAgent
/// can always read them.
@MainActor @Observable
final class WallpaperStore {
    private(set) var screens: [String: ScreenWallpapers] = [:]
    private(set) var profiles: [Profile] = []
    private var lastProfileID: UUID? {
        didSet { defaults.set(lastProfileID?.uuidString, forKey: "lastProfileID") }
    }
    private(set) var displays: [Display]
    private(set) var lastError: String?
    /// The last clear or replace, until the next change.
    private(set) var undoable: UndoableChange?
    private var importing: Set<ImportKey> = []
    /// Files being copied in, not yet referenced by `screens`.
    @ObservationIgnored private var reservedImages: Set<String> = []

    struct UndoableChange {
        /// Each changed screen's entry from before the change.
        let previous: [String: ScreenWallpapers]
        let message: String
    }

    private struct ImportKey: Hashable {
        let display: String
        let slot: Slot
    }

    /// How far each video being converted has got (0–1).
    private var videoProgress: [ImportKey: Double] = [:]
    /// Running video conversions, so they can be cancelled. The ID tells a
    /// late progress update from an old conversion apart from the current one.
    @ObservationIgnored private var videoTasks: [ImportKey: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Files each running conversion writes or reuses, kept from cleanup until it ends.
    @ObservationIgnored private var videoReservations: [UUID: Set<String>] = [:]

    /// Every video wallpaper is paused, from the panel. Not saved.
    var videosPaused = false {
        didSet { if videosPaused != oldValue { onPlaybackChange() } }
    }

    /// Called after any change so the engine can re-apply wallpapers.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called when videos are paused or resumed from the panel.
    @ObservationIgnored var onPlaybackChange: () -> Void = {}
    /// Called with a display's ID just before its desktop image is cleared,
    /// so the engine can show the macOS default there instead.
    @ObservationIgnored var onDesktopCleared: (String) -> Void = { _ in }

    @ObservationIgnored let directory: URL
    @ObservationIgnored let imagesDirectory: URL
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let profilesURL: URL
    @ObservationIgnored private let defaults: UserDefaults

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mosaic", isDirectory: true)
    }

    /// Tests pass their own folder, defaults and displays, so they never
    /// touch the real ones.
    init(directory: URL = WallpaperStore.defaultDirectory,
         defaults: UserDefaults = .standard,
         displays: [Display]? = nil) {
        let support = directory
        self.directory = directory
        self.defaults = defaults
        self.displays = displays ?? Display.connected
        imagesDirectory = support.appendingPathComponent("Images", isDirectory: true)
        stateURL = support.appendingPathComponent("state.json")
        profilesURL = support.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var loadedEverything = true
        if let data = try? Data(contentsOf: stateURL) {
            if let saved = try? JSONDecoder().decode([String: ScreenWallpapers].self, from: data) {
                screens = saved
            } else {
                loadedEverything = false
            }
        }
        if let data = try? Data(contentsOf: profilesURL) {
            if let saved = try? JSONDecoder().decode([Profile].self, from: data) {
                profiles = saved
            } else {
                loadedEverything = false
            }
        }
        lastProfileID = defaults.string(forKey: "lastProfileID").flatMap(UUID.init)
        // Images kept for an undo that was still pending when the app quit. Only
        // when both files were read, or an unreadable one would lose its images.
        if loadedEverything { removeUnusedImages() }
    }

    /// The profile last applied or saved, so edits made afterwards can be saved back to it.
    var lastProfile: Profile? {
        profiles.first { $0.id == lastProfileID }
    }

    /// The profile the current choices match exactly, if any.
    var activeProfile: Profile? {
        profiles.first { $0.screens == screens }
    }

    func wallpapers(for display: Display) -> ScreenWallpapers {
        screens[display.id] ?? ScreenWallpapers()
    }

    func imageURL(_ fileName: String?) -> URL? {
        fileName.map { imagesDirectory.appendingPathComponent($0) }
    }

    /// The picture for a slot's file: the image itself, or a video's still
    /// frame (what the system wallpaper, the lock screen and the tile show).
    func pictureURL(_ fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return imageURL(VideoFile(fileName: fileName)?.stillName ?? fileName)
    }

    /// Whether any connected screen's desktop is a video.
    var hasVideos: Bool {
        displays.contains { VideoFile.isVideo(wallpapers(for: $0).desktop) }
    }

    func refreshDisplays() {
        displays = Display.connected
    }

    func isImporting(_ slot: Slot, display: Display) -> Bool {
        importing.contains(ImportKey(display: display.id, slot: slot))
    }

    /// Copies the image in the background (it may be large, on a slow disk, or
    /// an iCloud file still downloading), then uses it.
    func setImage(from source: URL, slot: Slot, display: Display) {
        let destination = beginImport(slot: slot, displayID: display.id, fileExtension: source.pathExtension)
        let displayID = display.id
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    return nil
                } catch {
                    return error
                }
            }.value
            finishImport(destination, error: error, sourceName: source.lastPathComponent, slot: slot, displayID: displayID)
        }
    }

    /// Uses a picked or dropped file: a video goes through `setVideo`, anything else is copied as an image.
    func setMedia(from source: URL, slot: Slot, display: Display) {
        if VideoFile.isVideoSource(source) {
            setVideo(from: source, slot: slot, display: display)
        } else {
            setImage(from: source, slot: slot, display: display)
        }
    }

    // MARK: Videos

    /// How far a slot's video conversion has got (0–1), or nil when none is running.
    func videoProgress(_ slot: Slot, display: Display) -> Double? {
        videoProgress[ImportKey(display: display.id, slot: slot)]
    }

    /// Converts a video for a screen's desktop at the default settings and
    /// uses it. The lock screen can't play video, so it refuses one.
    /// `isTemporary`: the source is a copy made for this (say, of a video
    /// dragged from Photos), so no link to it is kept and it's deleted afterwards.
    func setVideo(from source: URL, slot: Slot, display: Display, isTemporary: Bool = false) {
        guard slot == .desktop else {
            lastError = "The lock screen can only show images."
            return
        }
        let replaced = wallpapers(for: display).desktop != nil
        convertVideo(from: source, format: VideoFormat.default(in: defaults), displayID: display.id,
                     linksOriginal: !isTemporary, deletesSource: isTemporary, sourceName: source.lastPathComponent,
                     undo: replaced ? "Replaced the desktop \(mediaWord(wallpapers(for: display).desktop)) on \(display.name)" : nil)
    }

    /// The settings a screen's desktop video is stored at, or nil when it isn't a video.
    func videoFormat(on display: Display) -> VideoFormat? {
        wallpapers(for: display).desktop.flatMap(VideoFile.init(fileName:))?.format
    }

    /// Whether a screen's video can be stored at `format`: it needs no more
    /// than the stored copy kept, or the original file can still be found.
    func canUse(_ format: VideoFormat, on display: Display) -> Bool {
        guard let current = wallpapers(for: display).desktop.flatMap(VideoFile.init(fileName:)) else { return false }
        return format.isAtMost(current.format) || originalURL(of: current) != nil
    }

    /// Stores a screen's desktop video again at other settings: from the
    /// original file when it can still be found, otherwise from the stored
    /// copy, which only works for settings no higher than it has.
    func setVideoFormat(_ format: VideoFormat, display: Display) {
        guard let name = wallpapers(for: display).desktop, let current = VideoFile(fileName: name),
              current.format != format, let stored = imageURL(name)
        else { return }
        let fallback = format.isAtMost(current.format) ? stored : nil
        let undo = "Changed the desktop video on \(display.name) to \(format.title)"
        if let original = originalURL(of: current) {
            convertVideo(from: original, expectedHash: current.sourceHash, fallback: fallback, format: format,
                         displayID: display.id, linksOriginal: true, sourceName: original.lastPathComponent, undo: undo)
        } else if let fallback {
            convertVideo(from: fallback, knownHash: current.sourceHash, format: format, displayID: display.id,
                         linksOriginal: false, sourceName: name, undo: undo)
        } else {
            lastError = Self.originalMissing
        }
    }

    private static let originalMissing = "The original video can't be found. Choose the video again to use a higher setting."

    /// Stops a slot's video conversion; the slot keeps what it had.
    func cancelVideoConversion(_ slot: Slot, display: Display) {
        videoTasks[ImportKey(display: display.id, slot: slot)]?.task.cancel()
    }

    /// The original file a stored video was made from, if it's still there.
    private func originalURL(of video: VideoFile) -> URL? {
        guard let data = try? Data(contentsOf: imagesDirectory.appendingPathComponent(video.originalName)) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// The longest side a stored video needs: the largest connected screen's,
    /// and at least 4K so a bigger screen plugged in later still looks sharp.
    private var videoLongSide: Int {
        let screens = displays.map { display in
            let frame = display.screen.frame
            return Int(max(frame.width, frame.height) * display.screen.backingScaleFactor)
        }
        return max(VideoEncoder.minimumLongSide, screens.max() ?? 0)
    }

    private func mediaWord(_ fileName: String?) -> String {
        VideoFile.isVideo(fileName) ? "video" : "image"
    }

    /// Converts `source` in the background (see VideoEncoder), saves its still
    /// frame and a bookmark to the original, then puts it on the screen's
    /// desktop. A video already stored at these settings is reused.
    /// `expectedHash`: the source must still be this file; if it isn't,
    /// `fallback` (the stored copy) is used instead, when there is one.
    private func convertVideo(from source: URL, knownHash: String? = nil, expectedHash: String? = nil, fallback: URL? = nil,
                              format: VideoFormat, displayID: String, linksOriginal: Bool, deletesSource: Bool = false,
                              sourceName: String, undo: String?) {
        let key = ImportKey(display: displayID, slot: .desktop)
        videoTasks[key]?.task.cancel()
        let id = UUID()
        let temporary = "\(id.uuidString).mov"
        importing.insert(key)
        videoProgress[key] = 0
        videoReservations[id] = [temporary]
        let directory = imagesDirectory
        let longSide = videoLongSide

        let task = Task { [weak self] in
            var input = source
            var links = linksOriginal
            do {
                var hash: String
                if let knownHash {
                    hash = knownHash
                } else {
                    hash = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: source) }.value
                }
                if let expectedHash, hash != expectedHash {
                    guard let fallback else { throw VideoEncoder.Failure(message: Self.originalMissing) }
                    input = fallback
                    hash = expectedHash
                    links = false
                }
                try Task.checkCancellation()
                let file = VideoFile(sourceHash: hash, format: format)
                self?.videoReservations[id, default: []].formUnion([file.fileName, file.stillName, file.originalName])
                let video = directory.appendingPathComponent(file.fileName)
                let still = directory.appendingPathComponent(file.stillName)
                let fileManager = FileManager.default
                if !fileManager.fileExists(atPath: video.path) {
                    let converted = directory.appendingPathComponent(temporary)
                    try await VideoEncoder.encode(input, to: converted, format: format, maxLongSide: longSide) { done in
                        Task { @MainActor in self?.reportProgress(done, key: key, id: id) }
                    }
                    try Task.checkCancellation()
                    if fileManager.fileExists(atPath: video.path) {
                        try? fileManager.removeItem(at: converted)
                    } else {
                        try fileManager.moveItem(at: converted, to: video)
                    }
                }
                if !fileManager.fileExists(atPath: still.path) {
                    try await VideoEncoder.writeStill(of: video, to: still)
                }
                if links, let bookmark = try? source.bookmarkData() {
                    try? bookmark.write(to: directory.appendingPathComponent(file.originalName), options: .atomic)
                }
                try Task.checkCancellation()
                self?.finishVideo(file.fileName, key: key, id: id, undo: undo)
            } catch {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(temporary))
                self?.finishVideo(nil, key: key, id: id, undo: nil)
                if !(error is CancellationError) { self?.importFailed(sourceName, error) }
            }
            if deletesSource { try? FileManager.default.removeItem(at: source) }
        }
        videoTasks[key] = (id, task)
    }

    private func reportProgress(_ done: Double, key: ImportKey, id: UUID) {
        guard videoTasks[key]?.id == id else { return }
        videoProgress[key] = done
    }

    /// Ends a conversion: puts the video on its screen, or just tidies up when
    /// `fileName` is nil (it failed or was cancelled).
    private func finishVideo(_ fileName: String?, key: ImportKey, id: UUID, undo: String?) {
        // A newer conversion for this slot took over; it owns the slot's state.
        let isCurrent = videoTasks[key]?.id == id
        if isCurrent {
            videoTasks[key] = nil
            videoProgress[key] = nil
            importing.remove(key)
        }
        videoReservations[id] = nil
        guard isCurrent, let fileName, let display = displays.first(where: { $0.id == key.display }) else {
            removeUnusedImages()
            return
        }
        lastError = nil
        update(display, undo: undo) { $0.desktop = fileName }
    }

    /// Starts copying an image into a slot: shows the slot as busy and
    /// reserves a temporary file for the copy, so cleanup can't delete it
    /// before the copy finishes. Always followed by `finishImport`.
    func beginImport(slot: Slot, displayID: String, fileExtension: String) -> URL {
        let name = "\(UUID().uuidString).\(Self.normalizedExtension(fileExtension))"
        importing.insert(ImportKey(display: displayID, slot: slot))
        reservedImages.insert(name)
        return imagesDirectory.appendingPathComponent(name)
    }

    /// Uses the copied image, or reports why the copy failed. The copy is
    /// renamed after a hash of its contents, so the same image picked for
    /// several slots is stored once.
    func finishImport(_ temporary: URL, error: Error?, sourceName: String, slot: Slot, displayID: String) {
        let key = ImportKey(display: displayID, slot: slot)
        if let error {
            importing.remove(key)
            reservedImages.remove(temporary.lastPathComponent)
            importFailed(sourceName, error)
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        Task {
            let hash = await Task.detached(priority: .userInitiated) {
                Result { try Self.sha256(of: temporary) }
            }.value
            importing.remove(key)
            reservedImages.remove(temporary.lastPathComponent)
            let fileName: String
            switch hash {
            case .failure(let error):
                importFailed(sourceName, error)
                try? FileManager.default.removeItem(at: temporary)
                return
            case .success(let hex):
                // On the main actor, like cleanup, so an existing file can't be
                // deleted between this check and `update` using it.
                fileName = storeOnce(temporary, as: "\(hex).\(temporary.pathExtension)")
            }
            guard let display = displays.first(where: { $0.id == displayID }) else {
                // The screen went away during the copy.
                removeUnusedImages()
                return
            }
            lastError = nil
            let replaced = wallpapers(for: display)[slot] != nil
            let undo = replaced ? "Replaced the \(slot.title.lowercased()) image on \(display.name)" : nil
            update(display, undo: undo) { $0[slot] = fileName }
        }
    }

    /// Moves the temporary copy to `name`, or drops it when an identical image
    /// is already stored there. Returns the file name to use.
    private func storeOnce(_ temporary: URL, as name: String) -> String {
        let destination = imagesDirectory.appendingPathComponent(name)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: temporary)
            return name
        }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
            return name
        } catch {
            Log.imports.error("Could not rename \(temporary.lastPathComponent, privacy: .public) to \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            return temporary.lastPathComponent
        }
    }

    /// `jpeg` and `jpg` give the same name, so the same bytes match.
    private static func normalizedExtension(_ ext: String) -> String {
        guard !ext.isEmpty else { return "img" }
        return (UTType(filenameExtension: ext)?.preferredFilenameExtension ?? ext).lowercased()
    }

    /// Reads the file in 1 MB chunks, so a large photo isn't loaded whole.
    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func importFailed(_ sourceName: String, _ error: Error) {
        Log.imports.error("Could not use \(sourceName, privacy: .public): \(String(describing: error), privacy: .public)")
        lastError = "Couldn't use \(sourceName): \(error.localizedDescription)"
    }

    func dismissError() {
        lastError = nil
    }

    func clear(_ slot: Slot, display: Display) {
        cancelVideoConversion(slot, display: display)
        let current = wallpapers(for: display)[slot]
        guard current != nil else { return }
        if slot == .desktop { onDesktopCleared(display.id) }
        update(display, undo: "Cleared the \(slot.title.lowercased()) \(mediaWord(current)) on \(display.name)") { $0[slot] = nil }
    }

    /// Puts back the images from before the last change that offered Undo.
    func undo() {
        guard let change = undoable else { return }
        undoable = nil
        for (id, entry) in change.previous {
            screens[id] = entry == ScreenWallpapers() ? nil : entry
        }
        save()
        removeUnusedImages()
        onChange()
    }

    /// Ends the chance to undo; the images it kept can now be deleted.
    func dismissUndo() {
        guard undoable != nil else { return }
        undoable = nil
        removeUnusedImages()
    }

    func setLockSameAsDesktop(_ same: Bool, display: Display) {
        update(display) { $0.lockSameAsDesktop = same }
    }

    // MARK: Tile menu

    /// The image to show in a slot. A lock slot that follows the desktop has none of its own.
    func image(_ slot: Slot, on display: Display) -> String? {
        let entry = wallpapers(for: display)
        return slot == .lock && entry.lockSameAsDesktop ? nil : entry[slot]
    }

    /// Puts this slot's image in the same slot on every other connected screen.
    func useOnAllScreens(_ slot: Slot, from display: Display) {
        let others = displays.filter { $0.id != display.id }
        copy(slot, from: display, to: others, undo: "Used the \(slot.title.lowercased()) image from \(display.name) on all screens")
    }

    /// Puts this slot's image in the same slot on another screen.
    func copy(_ slot: Slot, from display: Display, to target: Display) {
        copy(slot, from: display, to: [target], undo: "Copied the \(slot.title.lowercased()) image to \(target.name)")
    }

    private func copy(_ slot: Slot, from display: Display, to targets: [Display], undo: String) {
        guard let file = image(slot, on: display), !targets.isEmpty else { return }
        let scaling = wallpapers(for: display).scaling(slot)
        update(targets, undo: undo) { _, entry in
            entry[slot] = file
            entry.setScaling(scaling, for: slot)
            // Asking for this lock image means showing it, not the desktop.
            if slot == .lock { entry.lockSameAsDesktop = false }
        }
    }

    func setScaling(_ scaling: Scaling, _ slot: Slot, display: Display) {
        guard wallpapers(for: display).scaling(slot) != scaling else { return }
        update(display) { $0.setScaling(scaling, for: slot) }
    }

    /// Whether the screen has two different images to swap.
    func canSwap(on display: Display) -> Bool {
        let entry = wallpapers(for: display)
        guard !entry.lockSameAsDesktop, let desktop = entry.desktop, let lock = entry.lock else { return false }
        // The lock screen can't play a video.
        return desktop != lock && !VideoFile.isVideo(desktop)
    }

    func swapDesktopAndLock(on display: Display) {
        guard canSwap(on: display) else { return }
        update(display, undo: "Swapped the desktop and lock screen images on \(display.name)") { entry in
            swap(&entry.desktop, &entry.lock)
            swap(&entry.desktopScaling, &entry.lockScaling)
        }
    }

    /// Whether another profile already has this name, ignoring case and
    /// surrounding spaces. `profile` is the one being renamed, if any.
    func isProfileNameTaken(_ name: String, excluding profile: Profile? = nil) -> Bool {
        let wanted = Self.normalizedName(name)
        return profiles.contains { $0.id != profile?.id && Self.normalizedName($0.name) == wanted }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func saveProfile(named name: String) {
        guard !isProfileNameTaken(name) else { return }
        let profile = Profile(name: name, screens: screens)
        profiles.append(profile)
        lastProfileID = profile.id
        saveProfiles()
    }

    func overwrite(_ profile: Profile) {
        changeProfile(profile) { $0.screens = screens }
        removeUnusedImages()
    }

    func rename(_ profile: Profile, to name: String) {
        guard !isProfileNameTaken(name, excluding: profile) else { return }
        changeProfile(profile) { $0.name = name }
    }

    func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        if lastProfileID == profile.id { lastProfileID = nil }
        saveProfiles()
        removeUnusedImages()
    }

    func apply(_ profile: Profile) {
        screens = profile.screens
        lastProfileID = profile.id
        undoable = nil
        save()
        removeUnusedImages()
        onChange()
    }

    private func changeProfile(_ profile: Profile, _ change: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        change(&profiles[index])
        saveProfiles()
    }

    /// `undo` describes the change when it loses an image, so it can be undone
    /// until the next change.
    private func update(_ display: Display, undo: String? = nil, _ change: (inout ScreenWallpapers) -> Void) {
        update([display], undo: undo) { _, entry in change(&entry) }
    }

    /// Changes several screens at once, with one Undo for all of them.
    private func update(_ targets: [Display], undo: String? = nil,
                        _ change: (Display, inout ScreenWallpapers) -> Void) {
        var previous: [String: ScreenWallpapers] = [:]
        for display in targets {
            var entry = wallpapers(for: display)
            previous[display.id] = entry
            change(display, &entry)
            screens[display.id] = entry == ScreenWallpapers() ? nil : entry
        }
        undoable = undo.map { UndoableChange(previous: previous, message: $0) }
        save()
        removeUnusedImages()
        onChange()
    }

    private func save() {
        write(screens, to: stateURL, what: "state")
    }

    private func saveProfiles() {
        write(profiles, to: profilesURL, what: "profiles")
    }

    private func write(_ value: some Encodable, to url: URL, what: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.storage.error("Could not save \(what, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The space every stored image and video takes, in bytes.
    func storageUsed() async -> Int64 {
        let directory = imagesDirectory
        return await Task.detached(priority: .utility) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.reduce(Int64(0)) { total, name in
                let size = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                return total + Int64(size?.totalFileAllocatedSize ?? 0)
            }
        }.value
    }

    /// Deletes images that neither the current choices, any profile, a pending
    /// undo, nor a copy still in progress use.
    private func removeUnusedImages() {
        let all = [screens] + profiles.map(\.screens)
        let entries = all.flatMap(\.values) + (undoable?.previous.values.map { $0 } ?? [])
        let named = Set(entries.flatMap { [$0.desktop, $0.lock] }.compactMap { $0 })
        // A video also needs its still frame and the bookmark to its original.
        let videoFiles = named.compactMap(VideoFile.init(fileName:)).flatMap { [$0.stillName, $0.originalName] }
        let used = named.union(videoFiles).union(reservedImages).union(videoReservations.values.joined())
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(file))
        }
        Thumbnails.shared.prune(keeping: used)
    }
}

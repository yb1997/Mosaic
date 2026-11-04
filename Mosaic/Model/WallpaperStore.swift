import AppKit
import Observation

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

    /// The lock image actually in use.
    var effectiveLock: String? { lockSameAsDesktop ? nil : lock }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktop = try container.decodeIfPresent(String.self, forKey: .desktop)
        lock = try container.decodeIfPresent(String.self, forKey: .lock)
        lockSameAsDesktop = try container.decodeIfPresent(Bool.self, forKey: .lockSameAsDesktop) ?? false
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
        didSet { UserDefaults.standard.set(lastProfileID?.uuidString, forKey: "lastProfileID") }
    }
    private(set) var displays: [Display] = Display.connected
    private(set) var lastError: String?
    /// The last clear or replace, until the next change.
    private(set) var undoable: UndoableChange?
    private var importing: Set<ImportKey> = []
    /// Files being copied in, not yet referenced by `screens`.
    @ObservationIgnored private var reservedImages: Set<String> = []

    struct UndoableChange {
        let displayID: String
        let previous: ScreenWallpapers
        let message: String
    }

    private struct ImportKey: Hashable {
        let display: String
        let slot: Slot
    }

    /// Called after any change so the engine can re-apply wallpapers.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored let imagesDirectory: URL
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let profilesURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mosaic", isDirectory: true)
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
        lastProfileID = UserDefaults.standard.string(forKey: "lastProfileID").flatMap(UUID.init)
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

    /// Starts copying an image into a slot: shows the slot as busy and
    /// reserves the file the copy goes to, so cleanup can't delete it before
    /// the copy finishes. Always followed by `finishImport`.
    func beginImport(slot: Slot, displayID: String, fileExtension: String) -> URL {
        let ext = fileExtension.isEmpty ? "img" : fileExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        importing.insert(ImportKey(display: displayID, slot: slot))
        reservedImages.insert(name)
        return imagesDirectory.appendingPathComponent(name)
    }

    /// Uses the copied image, or reports why the copy failed.
    func finishImport(_ destination: URL, error: Error?, sourceName: String, slot: Slot, displayID: String) {
        importing.remove(ImportKey(display: displayID, slot: slot))
        reservedImages.remove(destination.lastPathComponent)
        if let error {
            importFailed(sourceName, error)
            try? FileManager.default.removeItem(at: destination)
            return
        }
        guard let display = displays.first(where: { $0.id == displayID }) else {
            // The screen went away during the copy.
            removeUnusedImages()
            return
        }
        lastError = nil
        let replaced = wallpapers(for: display)[slot] != nil
        let undo = replaced ? "Replaced the \(slot.title.lowercased()) image on \(display.name)" : nil
        update(display, undo: undo) { $0[slot] = destination.lastPathComponent }
    }

    func importFailed(_ sourceName: String, _ error: Error) {
        lastError = "Couldn't use \(sourceName): \(error.localizedDescription)"
    }

    func dismissError() {
        lastError = nil
    }

    func clear(_ slot: Slot, display: Display) {
        update(display, undo: "Cleared the \(slot.title.lowercased()) image on \(display.name)") { $0[slot] = nil }
    }

    /// Puts back the screen's images from before the last clear or replace.
    func undo() {
        guard let change = undoable else { return }
        undoable = nil
        screens[change.displayID] = change.previous == ScreenWallpapers() ? nil : change.previous
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

    func saveProfile(named name: String) {
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
        var entry = wallpapers(for: display)
        undoable = undo.map { UndoableChange(displayID: display.id, previous: entry, message: $0) }
        change(&entry)
        screens[display.id] = entry == ScreenWallpapers() ? nil : entry
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
            NSLog("Mosaic: could not save \(what): \(error)")
        }
    }

    /// Deletes images that neither the current choices, any profile, a pending
    /// undo, nor a copy still in progress use.
    private func removeUnusedImages() {
        let all = [screens] + profiles.map(\.screens)
        let entries = all.flatMap(\.values) + [undoable?.previous].compactMap { $0 }
        let used = Set(entries.flatMap { [$0.desktop, $0.lock] }.compactMap { $0 }).union(reservedImages)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(file))
        }
        Thumbnails.shared.prune(keeping: used)
    }
}

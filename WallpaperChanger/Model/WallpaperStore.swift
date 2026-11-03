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

    subscript(slot: Slot) -> String? {
        get { slot == .desktop ? desktop : lock }
        set { if slot == .desktop { desktop = newValue } else { lock = newValue } }
    }
}

/// Picked images and where they live. Images are copied into the app's own
/// folder so they keep working if the originals move, and so WallpaperAgent
/// can always read them.
@MainActor @Observable
final class WallpaperStore {
    private(set) var screens: [String: ScreenWallpapers] = [:]
    private(set) var displays: [Display] = Display.connected
    private(set) var lastError: String?

    /// Called after any change so the engine can re-apply wallpapers.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored let imagesDirectory: URL
    @ObservationIgnored private let stateURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperChanger", isDirectory: true)
        imagesDirectory = support.appendingPathComponent("Images", isDirectory: true)
        stateURL = support.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode([String: ScreenWallpapers].self, from: data) {
            screens = saved
        }
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

    func setImage(from source: URL, slot: Slot, display: Display) {
        let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.copyItem(at: source, to: imagesDirectory.appendingPathComponent(name))
            lastError = nil
        } catch {
            lastError = "Couldn't use \(source.lastPathComponent): \(error.localizedDescription)"
            return
        }
        update(display) { $0[slot] = name }
    }

    func clear(_ slot: Slot, display: Display) {
        update(display) { $0[slot] = nil }
    }

    private func update(_ display: Display, _ change: (inout ScreenWallpapers) -> Void) {
        var entry = wallpapers(for: display)
        change(&entry)
        screens[display.id] = entry == ScreenWallpapers() ? nil : entry
        save()
        removeUnusedImages()
        onChange()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(screens).write(to: stateURL, options: .atomic)
        } catch {
            NSLog("WallpaperChanger: could not save state: \(error)")
        }
    }

    private func removeUnusedImages() {
        let used = Set(screens.values.flatMap { [$0.desktop, $0.lock] }.compactMap { $0 })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(file))
        }
        Thumbnails.shared.prune(keeping: used)
    }
}

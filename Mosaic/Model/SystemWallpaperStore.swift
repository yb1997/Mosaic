import Darwin
import Foundation

/// PRIVATE: macOS's own wallpaper settings file, read and written directly.
/// See docs/PRIVATE_APIS.md. Used to put back a wallpaper that isn't one of
/// ours (a Photos picture, an aerial, Apple's dynamic wallpapers), which
/// NSWorkspace can neither read back nor set, and to make a screen's
/// wallpaper one of Mosaic's lock screen videos (docs/LOCK_SCREEN_VIDEO.md).
nonisolated enum SystemWallpaperStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static let aerialProvider = "com.apple.wallpaper.choice.aerials"
    static let imageProvider = "com.apple.wallpaper.choice.image"

    static func snapshot() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Writes a snapshot back and restarts WallpaperAgent so it reloads it.
    static func restore(_ data: Data) {
        install(data)
    }

    // MARK: Choices

    /// The settings as a mutable tree, or nil when they can't be read or
    /// aren't laid out as expected (then nothing is touched).
    static func load() -> NSMutableDictionary? {
        guard let data = snapshot() else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> NSMutableDictionary? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil),
              let store = plist as? NSMutableDictionary, store["Displays"] is NSMutableDictionary
        else { return nil }
        return store
    }

    /// Every entry for a screen: the top-level one and one per Space. All of
    /// them have to agree, or WallpaperAgent copies the current Space's choice
    /// back over the top-level one when it starts (spike run 1).
    private static func entries(for displayID: String, in store: NSDictionary) -> [NSMutableDictionary] {
        keyedEntries(for: displayID, in: store).map(\.entry)
    }

    /// The same, each with a key that finds it again: "" for the top-level
    /// entry, the Space's ID for the others.
    private static func keyedEntries(for displayID: String, in store: NSDictionary) -> [(key: String, entry: NSMutableDictionary)] {
        var all: [(key: String, entry: NSMutableDictionary)] = []
        if let top = (store["Displays"] as? NSDictionary)?[displayID] as? NSMutableDictionary {
            all.append(("", top))
        }
        let spaces = (store["Spaces"] as? NSDictionary) ?? [:]
        for case let id as String in spaces.allKeys {
            if let entry = ((spaces[id] as? NSDictionary)?["Displays"] as? NSDictionary)?[displayID] as? NSMutableDictionary {
                all.append((id, entry))
            }
        }
        return all
    }

    /// A screen shows its Desktop choice, or its Linked one when it is set to
    /// one picture for desktop and lock.
    private static func surface(of entry: NSDictionary) -> String {
        entry["Type"] as? String == "linked" ? "Linked" : "Desktop"
    }

    private static func choice(in entry: NSDictionary, surface: String? = nil) -> NSDictionary? {
        ((entry[surface ?? Self.surface(of: entry)] as? NSDictionary)?["Content"] as? NSDictionary)
            .flatMap { ($0["Choices"] as? [NSDictionary])?.first }
    }

    private static func aerialAsset(of choice: NSDictionary?) -> String? {
        guard let choice, choice["Provider"] as? String == aerialProvider,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return nil }
        return configuration["assetID"] as? String
    }

    /// The `file://` address of a picture choice, as it's stored.
    private static func imageAddress(of choice: NSDictionary?) -> String? {
        guard let choice, choice["Provider"] as? String == imageProvider,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return nil }
        return (configuration["url"] as? NSDictionary)?["relative"] as? String
    }

    private static func imageChoice(_ image: URL) -> NSDictionary? {
        let settings: NSDictionary = ["type": "imageFile", "url": ["relative": image.absoluteString] as NSDictionary]
        guard let configuration = try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
        else { return nil }
        return ["Configuration": configuration, "Files": [] as NSArray, "Provider": imageProvider]
    }

    /// Whether a screen saver choice is something Mosaic put there: one of
    /// the aerials in `assets`, or a picture stored in `picturesIn`.
    private static func isMosaics(_ choice: NSDictionary?, assets: Set<String>, picturesIn: URL?) -> Bool {
        if let asset = aerialAsset(of: choice), assets.contains(asset) { return true }
        guard let picturesIn, let address = imageAddress(of: choice), let path = URL(string: address)?.path else { return false }
        return path.hasPrefix(picturesIn.path + "/")
    }

    /// A linked entry's one choice is also its screen saver; any other entry
    /// has a separate `Idle` one.
    private static func hasIdle(_ entry: NSDictionary) -> Bool {
        surface(of: entry) != "Linked"
    }

    /// The aerial asset every entry for the screen shows, or nil when they
    /// show something else or don't all agree.
    static func aerialAsset(on displayID: String, in store: NSDictionary) -> String? {
        let all = entries(for: displayID, in: store)
        guard !all.isEmpty else { return nil }
        let assets = all.map { aerialAsset(of: choice(in: $0)) }
        guard let first = assets.first, let asset = first, assets.allSatisfy({ $0 == asset }) else { return nil }
        return asset
    }

    /// Whether every screen saver choice for the screen is aerial `assetID`.
    /// When the Mac locks after sitting idle, the screen saver starts first
    /// and the lock screen shows it, not the desktop choice.
    static func screenSaverShows(_ assetID: String, on displayID: String, in store: NSDictionary) -> Bool {
        entries(for: displayID, in: store).filter(hasIdle).allSatisfy {
            aerialAsset(of: choice(in: $0, surface: "Idle")) == assetID
        }
    }

    /// Whether every screen saver choice for the screen is the picture `image`.
    static func screenSaverShows(image: URL, on displayID: String, in store: NSDictionary) -> Bool {
        entries(for: displayID, in: store).filter(hasIdle).allSatisfy {
            imageAddress(of: choice(in: $0, surface: "Idle")) == image.absoluteString
        }
    }

    /// Whether any screen saver choice for the screen is an aerial in `assets`.
    static func screenSaverShowsAny(of assets: Set<String>, on displayID: String, in store: NSDictionary) -> Bool {
        entries(for: displayID, in: store).filter(hasIdle).contains {
            aerialAsset(of: choice(in: $0, surface: "Idle")).map(assets.contains) ?? false
        }
    }

    /// Makes every screen saver choice for the screen the picture `image`,
    /// leaving its wallpaper alone.
    static func setScreenSaver(image: URL, on displayID: String, in store: NSMutableDictionary, now: Date = Date()) -> Bool {
        guard let choice = imageChoice(image) else { return false }
        let all = entries(for: displayID, in: store).filter(hasIdle)
        guard !all.isEmpty else { return false }
        for entry in all { entry["Idle"] = surfaceValue(choice, options: nil, now: now) }
        return true
    }

    /// Makes every entry for the screen show aerial `assetID`, as its
    /// wallpaper and as its screen saver.
    static func setAerial(_ assetID: String, on displayID: String, in store: NSMutableDictionary, now: Date = Date()) -> Bool {
        guard let configuration = try? PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        else { return false }
        let choice: NSDictionary = ["Configuration": configuration, "Files": [] as NSArray, "Provider": aerialProvider]
        guard set(choice, options: nil, on: displayID, in: store, now: now) else { return false }
        for entry in entries(for: displayID, in: store) where hasIdle(entry) {
            entry["Idle"] = surfaceValue(choice, options: nil, now: now)
        }
        return true
    }

    /// The screen saver choice of each entry for the screen, by entry key,
    /// leaving out Mosaic's own (an aerial in `ignoring`, a picture in
    /// `picturesIn`), as a property list to keep until `restoreScreenSavers`
    /// puts them back.
    static func screenSavers(on displayID: String, in store: NSDictionary, ignoring: Set<String>, picturesIn: URL? = nil) -> Data? {
        var saved: [String: Any] = [:]
        for (key, entry) in keyedEntries(for: displayID, in: store) where hasIdle(entry) {
            guard let idle = entry["Idle"] as? NSDictionary else { continue }
            if isMosaics(choice(in: entry, surface: "Idle"), assets: ignoring, picturesIn: picturesIn) { continue }
            saved[key] = idle
        }
        return try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
    }

    /// The wallpaper choice of each entry for the screen, by entry key,
    /// leaving out Mosaic's own, to keep until `restoreWallpapers` puts them
    /// back. NSWorkspace can't set Photos pictures, aerials or dynamic
    /// wallpapers, so a lock video's aerial would otherwise lose them for good.
    static func wallpapers(on displayID: String, in store: NSDictionary, ignoring: Set<String>, picturesIn: URL? = nil) -> Data? {
        var saved: [String: Any] = [:]
        for (key, entry) in keyedEntries(for: displayID, in: store) {
            guard let value = entry[surface(of: entry)] as? NSDictionary,
                  !isMosaics(choice(in: entry), assets: ignoring, picturesIn: picturesIn)
            else { continue }
            saved[key] = value
        }
        return try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
    }

    /// Puts back what `wallpapers` saved, in every entry that shows something
    /// of Mosaic's. An entry with nothing saved (a Space made since) gets the
    /// screen's top-level choice. Returns false, changing nothing, when
    /// nothing was saved.
    static func restoreWallpapers(_ saved: Data?, replacing assets: Set<String>, picturesIn: URL? = nil, on displayID: String, in store: NSMutableDictionary) -> Bool {
        guard let choices = saved.flatMap({ try? PropertyListSerialization.propertyList(from: $0, options: .mutableContainersAndLeaves, format: nil) as? NSDictionary }),
              let fallback = choices[""] ?? choices.allValues.first
        else { return false }
        for (key, entry) in keyedEntries(for: displayID, in: store)
        where isMosaics(choice(in: entry), assets: assets, picturesIn: picturesIn) {
            entry[surface(of: entry)] = choices[key] ?? fallback
        }
        return true
    }

    /// The picture file a saved wallpaper (from `wallpapers`) shows, if it's one.
    static func savedPicture(_ saved: Data?) -> URL? {
        guard let choices = saved.flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary }),
              let value = (choices[""] ?? choices.allValues.first) as? NSDictionary,
              let first = ((value["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary])?.first,
              let address = imageAddress(of: first), let url = URL(string: address), url.isFileURL
        else { return nil }
        return url
    }

    /// How many entries the screen has: one more for each Space it's been on.
    static func entryCount(on displayID: String, in store: NSDictionary) -> Int {
        entries(for: displayID, in: store).count
    }

    /// `newer` laid over `older`, both saved choices: an entry that was
    /// skipped because it already showed Mosaic's aerial keeps what was saved
    /// for it earlier.
    static func mergeSaved(_ older: Data?, _ newer: Data?) -> Data? {
        func decode(_ data: Data?) -> [String: Any] {
            data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        }
        let merged = decode(older).merging(decode(newer)) { $1 }
        return try? PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
    }

    /// Puts back the screen saver choices `screenSavers` saved, in the
    /// entries that still show something of Mosaic's (one of the aerials in
    /// `assets`, a picture in `picturesIn`). One with nothing saved loses its
    /// screen saver choice, so macOS uses its default. Entries showing
    /// anything else were changed since (in System Settings) and are left
    /// alone. Returns whether anything changed.
    @discardableResult
    static func restoreScreenSavers(_ saved: Data?, replacing assets: Set<String>, picturesIn: URL? = nil, on displayID: String, in store: NSMutableDictionary) -> Bool {
        let choices = saved.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: .mutableContainersAndLeaves, format: nil) as? NSDictionary } ?? [:]
        var changed = false
        for (key, entry) in keyedEntries(for: displayID, in: store) where hasIdle(entry) {
            guard isMosaics(choice(in: entry, surface: "Idle"), assets: assets, picturesIn: picturesIn) else { continue }
            entry["Idle"] = choices[key]
            changed = true
        }
        return changed
    }

    /// Makes every entry for the screen show the picture at `image`, filling
    /// the screen. Mosaic sets the real scaling afterwards, Space by Space.
    static func setImage(_ image: URL, on displayID: String, in store: NSMutableDictionary, now: Date = Date()) -> Bool {
        guard let choice = imageChoice(image) else { return false }
        return set(choice, options: nil, on: displayID, in: store, now: now)
    }

    private static func set(_ choice: NSDictionary, options: Data?, on displayID: String, in store: NSMutableDictionary, now: Date) -> Bool {
        let all = entries(for: displayID, in: store)
        guard !all.isEmpty else { return false }
        for entry in all {
            entry[surface(of: entry)] = surfaceValue(choice, options: options, now: now)
            if entry["Type"] == nil { entry["Type"] = "individual" }
        }
        return true
    }

    private static func surfaceValue(_ choice: NSDictionary, options: Data?, now: Date) -> NSMutableDictionary {
        let content = NSMutableDictionary(dictionary: ["Choices": [choice] as NSArray, "Shuffle": "$null"])
        if let options { content["EncodedOptionValues"] = options }
        return NSMutableDictionary(dictionary: ["Content": content, "LastSet": now, "LastUse": now])
    }

    // MARK: Writing with the agent restarted

    /// Writes the settings and restarts WallpaperAgent so it reads them.
    @discardableResult
    static func write(_ store: NSDictionary) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0) else { return false }
        return install(data)
    }

    /// The agent is paused first: it saves its own copy from time to time,
    /// and a save landing between the write and the restart would undo it.
    @discardableResult
    private static func install(_ data: Data) -> Bool {
        let agents = pids(of: "WallpaperAgent")
        agents.forEach { kill($0, SIGSTOP) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            agents.forEach { kill($0, SIGCONT) }
            Log.lockSwap.error("Could not write wallpaper settings: \(String(describing: error), privacy: .public)")
            return false
        }
        // Killed, not asked to quit, so it can't save its old settings on the way out.
        // launchd starts it again on demand.
        agents.forEach { kill($0, SIGKILL) }
        pids(of: "WallpaperAerialsExtension").forEach { kill($0, SIGTERM) }
        return true
    }

    /// Restarts WallpaperAgent and its aerials extension so they read the
    /// aerial catalog again; the settings file is left alone.
    static func restartAgent() {
        (pids(of: "WallpaperAerialsExtension") + pids(of: "WallpaperAgent")).forEach { kill($0, SIGTERM) }
    }

    /// Process IDs of this user's processes with that exact name. Asks the
    /// kernel directly: spawning pgrep blocked the main thread for a while.
    static func pids(of name: String) -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 16)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &all, Int32(all.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 64)
        return all.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { pid in
            pid > 0 && proc_name(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == name
        }
    }
}

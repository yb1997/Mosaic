import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PRIVATE: macOS's aerial wallpaper catalog, read and written directly so a
/// video can play on the lock screen (docs/LOCK_SCREEN_VIDEO.md,
/// docs/PRIVATE_APIS.md). Each lock screen video becomes an asset in a
/// "Mosaic" category: its file in `aerials/videos/<id>.mov`, a thumbnail in
/// `aerials/thumbnails/<id>.png`, and an entry in the catalog WallpaperAgent
/// reads. All of it is undocumented and may change with any macOS update.
nonisolated enum AerialCatalog {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    static var videosDirectory: URL { root.appendingPathComponent("videos", isDirectory: true) }
    static var thumbnailsDirectory: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }
    /// Unpacked from the manifest macOS downloads. On macOS 27.2 the aerials
    /// extension doesn't read it: with no override it loads the catalog in its
    /// own bundle, so an asset listed only here fails and the lock screen shows
    /// Golden Gate. Kept up to date because Native Aerials rebuilds its
    /// override from it.
    static var manifestURL: URL { root.appendingPathComponent("manifest/entries.json") }
    /// The override Mosaic sets while it has lock screen videos and no other
    /// app has set one.
    static var ownCatalogURL: URL { root.appendingPathComponent("mosaic/entries.json") }
    private static let bundledCatalogURL = URL(fileURLWithPath:
        "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")
    private static let forceLocalKey = "AerialManifestForceLocal"
    private static let overridePathKey = "AerialManifestLocalPathOverride"
    private static var preferences: UserDefaults? { UserDefaults(suiteName: "com.apple.wallpaper.aerial") }

    /// Fixed, so every Mosaic asset lands in one category.
    static let categoryID = "6D05A1C0-5E1F-4C3B-9D2A-4D6F7A8B9C01"
    static let subcategoryID = "6D05A1C0-5E1F-4C3B-9D2A-4D6F7A8B9C02"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The asset ID for a stored video shown at a scaling: the same inputs
    /// always give the same ID, so registering again changes nothing.
    static func assetID(for video: VideoFile, scaling: Scaling) -> String {
        var bytes = Array(SHA256.hash(data: Data("mosaic-aerial|\(video.fileName)|\(scaling.rawValue)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    /// The catalog the extension loads instead of its own, if one is set.
    private static func overrideURL() -> URL? {
        guard let prefs = preferences, prefs.bool(forKey: forceLocalKey),
              let path = prefs.string(forKey: overridePathKey) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// The catalogs to write: the manifest, and the override the extension
    /// actually reads.
    static func catalogURLs() -> [URL] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: manifestURL.path) { urls.append(manifestURL) }
        if let override = overrideURL(), override != manifestURL.standardizedFileURL { urls.append(override) }
        return urls
    }

    /// Whether Mosaic has to set its own override: not when another app's is
    /// in place, nor when its own is. An override whose file has gone is left
    /// over from an app that was removed.
    static func needsOwnOverride(current: URL?, fileExists: Bool) -> Bool {
        guard let current else { return true }
        return current != ownCatalogURL.standardizedFileURL && !fileExists
    }

    /// Held while a catalog is read, changed and saved: preparing one video,
    /// preparing another and cleaning up all run at once, and each would
    /// otherwise save over the others' changes.
    private static let catalogLock = NSLock()

    /// Makes sure the extension reads a catalog Mosaic can add to, creating
    /// Mosaic's own from the current one if needed. Returns true when the
    /// extension has to be restarted to read it.
    static func claimOverride() throws -> Bool {
        try catalogLock.withLock { try claimOverrideLocked() }
    }

    private static func claimOverrideLocked() throws -> Bool {
        let fileManager = FileManager.default
        let current = overrideURL()
        let isOwn = current == ownCatalogURL.standardizedFileURL
        let exists = current.map { fileManager.fileExists(atPath: $0.path) } ?? false
        guard isOwn || needsOwnOverride(current: current, fileExists: exists) else { return false }
        if isOwn, exists { return false }
        try fileManager.createDirectory(at: ownCatalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = fileManager.fileExists(atPath: manifestURL.path) ? manifestURL : bundledCatalogURL
        let catalog = try load(source)
        rebuildCategory(in: catalog)
        try save(catalog, to: ownCatalogURL)
        guard let prefs = preferences else { throw Failure(message: "macOS's aerial settings can't be changed.") }
        prefs.set(true, forKey: forceLocalKey)
        prefs.set(ownCatalogURL.path, forKey: overridePathKey)
        prefs.synchronize()
        return true
    }

    /// Takes Mosaic's override away, so macOS manages its catalog again.
    /// Returns whether there was one to take away.
    private static func releaseOverride() -> Bool {
        guard overrideURL() == ownCatalogURL.standardizedFileURL, let prefs = preferences else { return false }
        prefs.removeObject(forKey: forceLocalKey)
        prefs.removeObject(forKey: overridePathKey)
        prefs.synchronize()
        try? FileManager.default.removeItem(at: ownCatalogURL.deletingLastPathComponent())
        return true
    }

    static func videoURL(_ id: String) -> URL { videosDirectory.appendingPathComponent("\(id).mov") }
    static func thumbnailURL(_ id: String) -> URL { thumbnailsDirectory.appendingPathComponent("\(id).png") }

    /// Whether the asset's video is in place and every catalog lists it.
    static func isRegistered(_ id: String) -> Bool {
        let catalogs = catalogURLs()
        guard !catalogs.isEmpty, FileManager.default.fileExists(atPath: videoURL(id).path) else { return false }
        return catalogs.allSatisfy { url in
            (try? load(url)).map { assets(in: $0).contains { $0["id"] as? String == id } } ?? false
        }
    }

    /// Puts `video` (the lock screen copy) in place as asset `id` and lists
    /// it in every catalog. A catalog that already lists it is left alone.
    /// Returns true when the override had to be set again, as for `claimOverride`.
    @discardableResult
    static func register(_ id: String, video: URL, still: URL, scaling: Scaling) throws -> Bool {
        try catalogLock.withLock {
            let claimed = try claimOverrideLocked()
            try registerLocked(id, video: video, still: still, scaling: scaling)
            return claimed
        }
    }

    private static func registerLocked(_ id: String, video: URL, still: URL, scaling: Scaling) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let destination = videoURL(id)
        if !fileManager.fileExists(atPath: destination.path) {
            // On APFS this clones, so it takes no extra space.
            try fileManager.copyItem(at: video, to: destination)
        }
        let thumbnail = thumbnailURL(id)
        if !fileManager.fileExists(atPath: thumbnail.path) {
            try writeThumbnail(of: still, to: thumbnail)
        }
        for url in catalogURLs() {
            let catalog = try load(url)
            let listed = assets(in: catalog).contains { $0["id"] as? String == id }
            guard !listed || !hasValidCategory(catalog) else { continue }
            if !listed { add(id, video: destination, thumbnail: thumbnail, scaling: scaling, to: catalog) }
            rebuildCategory(in: catalog)
            try save(catalog, to: url)
        }
    }

    /// Removes every Mosaic asset not in `keeping`: catalog entries, videos
    /// and thumbnails, and Mosaic's override once nothing is left. Returns
    /// true when the agent needs a restart to read the catalog again: one
    /// macOS couldn't read was mended, or the override it reads has gone.
    @discardableResult
    static func unregister(keeping: Set<String>) throws -> Bool {
        try catalogLock.withLock { try unregisterLocked(keeping: keeping) }
    }

    private static func unregisterLocked(keeping: Set<String>) throws -> Bool {
        var removed: Set<String> = []
        var repaired = false
        for url in catalogURLs() {
            guard let catalog = try? load(url) else { continue }
            let before = assets(in: catalog)
            let ours = before.filter(isOurs).compactMap { $0["id"] as? String }
            let gone = Set(ours).subtracting(keeping)
            // A category pointing at a removed asset makes macOS reject the
            // whole catalog, every aerial included, so mend one found broken too.
            let broken = !hasValidCategory(catalog)
            guard !gone.isEmpty || broken else { continue }
            repaired = repaired || broken
            removed.formUnion(gone)
            catalog["assets"] = NSMutableArray(array: before.filter { !gone.contains($0["id"] as? String ?? "") })
            rebuildCategory(in: catalog)
            try save(catalog, to: url)
        }
        for id in removed {
            try? FileManager.default.removeItem(at: videoURL(id))
            try? FileManager.default.removeItem(at: thumbnailURL(id))
        }
        if keeping.isEmpty, ourAssetIDs().isEmpty, releaseOverride() { return true }
        return repaired
    }

    /// IDs of Mosaic assets in any catalog.
    static func ourAssetIDs() -> Set<String> {
        Set(catalogURLs().flatMap { url in
            ((try? load(url)).map(assets(in:)) ?? []).filter(isOurs).compactMap { $0["id"] as? String }
        })
    }

    // MARK: Files

    private static func isOurs(_ asset: NSDictionary) -> Bool {
        (asset["categories"] as? [String])?.contains(categoryID) == true
    }

    private static func assets(in catalog: NSDictionary) -> [NSDictionary] {
        catalog["assets"] as? [NSDictionary] ?? []
    }

    private static func load(_ url: URL) throws -> NSMutableDictionary {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers),
              let catalog = json as? NSMutableDictionary, catalog["assets"] is NSMutableArray
        else { throw Failure(message: "macOS's aerial list at \(url.path) can't be read.") }
        if !(catalog["categories"] is NSMutableArray) { catalog["categories"] = NSMutableArray() }
        return catalog
    }

    private static func save(_ catalog: NSDictionary, to url: URL) throws {
        guard hasValidCategory(catalog) else { throw Failure(message: "The aerial list would be invalid; not saved.") }
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// The same keys Apple's own assets have (checked on macOS 27.2).
    private static func add(_ id: String, video: URL, thumbnail: URL, scaling: Scaling, to catalog: NSMutableDictionary) {
        let gravity = switch scaling {
        case .fill: "resizeAspectFill"
        case .fit, .center: "resizeAspect"
        case .stretch: "resize"
        }
        (catalog["assets"] as? NSMutableArray)?.add([
            "accessibilityLabel": "Mosaic lock screen video",
            "categories": [categoryID],
            "id": id,
            "includeInShuffle": false,
            "localizedNameKey": "Mosaic",
            "pointsOfInterest": [:] as NSDictionary,
            "preferredOrder": 0,
            "previewImage": thumbnail.absoluteString,
            "shotID": "MOSAIC",
            "showInTopLevel": true,
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": video.absoluteString,
            "videoGravity": gravity,
        ] as NSDictionary)
    }

    /// Replaces the Mosaic category with one whose representative asset is
    /// one of Mosaic's assets still listed, or removes it when none are.
    /// macOS refuses the whole catalog (every aerial stops) when a category
    /// names an asset that isn't there (seen on macOS 27.2).
    static func rebuildCategory(in catalog: NSMutableDictionary) {
        let others = (catalog["categories"] as? [NSDictionary] ?? []).filter { $0["id"] as? String != categoryID }
        let categories = NSMutableArray(array: others)
        if let first = assets(in: catalog).first(where: isOurs), let id = first["id"] as? String {
            let preview = first["previewImage"] as? String ?? ""
            let subcategory: NSDictionary = [
                "id": subcategoryID, "localizedNameKey": "Mosaic", "localizedDescriptionKey": "Mosaic",
                "preferredOrder": 0, "previewImage": preview, "representativeAssetID": id,
            ]
            categories.add([
                "id": categoryID, "localizedNameKey": "Mosaic", "localizedDescriptionKey": "Mosaic",
                "preferredOrder": 100, "previewImage": preview, "representativeAssetID": id,
                "subcategories": [subcategory],
            ] as NSDictionary)
        }
        catalog["categories"] = categories
    }

    /// Whether the Mosaic category is there exactly when Mosaic has assets,
    /// and only names assets that are listed.
    static func hasValidCategory(_ catalog: NSDictionary) -> Bool {
        let listed = Set(assets(in: catalog).compactMap { $0["id"] as? String })
        let hasOurs = assets(in: catalog).contains(where: isOurs)
        let ours = (catalog["categories"] as? [NSDictionary] ?? []).filter { $0["id"] as? String == categoryID }
        guard let category = ours.first else { return !hasOurs }
        guard ours.count == 1, hasOurs else { return false }
        let named = [category["representativeAssetID"]] + (category["subcategories"] as? [NSDictionary] ?? []).map { $0["representativeAssetID"] }
        return named.allSatisfy { ($0 as? String).map(listed.contains) ?? true }
    }

    /// A PNG of the still frame, at most 800 pixels on its long side.
    private static func writeThumbnail(of still: URL, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(still as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 800,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary),
              let file = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(message: "The lock screen thumbnail can't be made.") }
        CGImageDestinationAddImage(file, image, nil)
        guard CGImageDestinationFinalize(file) else { throw Failure(message: "The lock screen thumbnail can't be saved.") }
    }
}

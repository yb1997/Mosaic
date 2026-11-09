// Spike 4: can a third-party video play on the lock screen as a custom
// "aerial"? The lock screen animates aerial wallpapers natively, so register
// the video as an aerial asset and make it a screen's desktop choice.
//
//   swiftc -O aerialspike.swift -o aerialspike
//   ./aerialspike show
//   ./aerialspike add <video.mov>                 # prints the new asset ID
//   ./aerialspike set <assetID> [--display <uuid>] # desktop (and lock) choice
//   ./aerialspike restore <backup dir>
//
// Every add/set first copies the catalog(s) and Index.plist into
// ~/backups/aerialspike-<stamp>/; restore puts them back, deletes the videos
// it added and restarts WallpaperAgent. All of it is private, undocumented
// and can break with any macOS update (see docs/LOCK_SCREEN_VIDEO.md).

import AppKit
import AVFoundation
import CoreGraphics

let home = FileManager.default.homeDirectoryForCurrentUser
let root = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
let storeURL = root.appendingPathComponent("Store/Index.plist")
let aerials = root.appendingPathComponent("aerials")
let videosDir = aerials.appendingPathComponent("videos")
let thumbsDir = aerials.appendingPathComponent("thumbnails")
let manifestURL = aerials.appendingPathComponent("manifest/entries.json")
let aerialProvider = "com.apple.wallpaper.choice.aerials"
// Fixed IDs so repeated adds land in one "Mosaic" category.
let categoryID = "6D05A1C0-5E1F-4C3B-9D2A-4D6F7A8B9C01"
let subcategoryID = "6D05A1C0-5E1F-4C3B-9D2A-4D6F7A8B9C02"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The catalog WallpaperAgent reads: the AerialManifestLocalPathOverride
/// default when AerialManifestForceLocal is set (Native Aerials sets both),
/// else the downloaded manifest.
func catalogURLs() -> (active: URL, override: Bool) {
    let prefs = UserDefaults(suiteName: "com.apple.wallpaper.aerial")
    if prefs?.bool(forKey: "AerialManifestForceLocal") == true,
       let path = prefs?.string(forKey: "AerialManifestLocalPathOverride") {
        return (URL(fileURLWithPath: path), true)
    }
    return (manifestURL, false)
}

func loadJSON(_ url: URL) -> NSMutableDictionary {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers),
          let dict = json as? NSMutableDictionary, dict["assets"] is NSMutableArray
    else { fail("cannot read catalog \(url.path)") }
    return dict
}

func writeJSON(_ dict: NSDictionary, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url, options: .atomic)
}

func loadStore() -> NSMutableDictionary {
    guard let data = try? Data(contentsOf: storeURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil),
          let dict = plist as? NSMutableDictionary
    else { fail("cannot read \(storeURL.path)") }
    for key in ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"] where dict[key] == nil {
        fail("Index.plist has no \(key); unknown layout, not touching it")
    }
    return dict
}

func makeBackup() -> URL {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let dir = home.appendingPathComponent("backups/aerialspike-\(stamp.string(from: Date()))")
    let fm = FileManager.default
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! fm.copyItem(at: storeURL, to: dir.appendingPathComponent("Index.plist"))
    try! fm.copyItem(at: manifestURL, to: dir.appendingPathComponent("manifest-entries.json"))
    let (active, override) = catalogURLs()
    if override {
        try! fm.copyItem(at: active, to: dir.appendingPathComponent("override-entries.json"))
        try! active.path.write(to: dir.appendingPathComponent("override-path.txt"), atomically: true, encoding: .utf8)
    }
    print("backup: \(dir.path)")
    return dir
}

func restartAgent() {
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    kill.arguments = ["WallpaperAgent", "WallpaperAerialsExtension"]
    try? kill.run()
    kill.waitUntilExit()
    Thread.sleep(forTimeInterval: 4)
}

func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "?" }
    return CFUUIDCreateString(nil, uuid) as String
}

func describeVideo(_ url: URL) -> String {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    var text = "?"
    Task {
        defer { sem.signal() }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, fps, formats) = try? await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        else { return }
        let fourCC = formats.first.map { d -> String in
            let t = CMFormatDescriptionGetMediaSubType(d)
            return String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        } ?? "?"
        text = "\(fourCC) \(Int(size.width))×\(Int(size.height)) \(String(format: "%.0f", fps)) fps"
    }
    sem.wait()
    return text
}

func show() {
    print("Displays:")
    for screen in NSScreen.screens {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        print("  \(screen.localizedName): \(displayUUID(id))")
    }
    let (active, override) = catalogURLs()
    print("Active catalog: \(active.path)\(override ? " (AerialManifestLocalPathOverride)" : "")")
    let catalog = loadJSON(active)
    let ours = (catalog["assets"] as! [NSDictionary]).filter {
        ($0["categories"] as? [String])?.contains(categoryID) == true
    }
    print("Mosaic assets in it: \(ours.count)")
    for asset in ours {
        let id = asset["id"] as! String
        let file = videosDir.appendingPathComponent("\(id).mov")
        let exists = FileManager.default.fileExists(atPath: file.path)
        print("  \(id) \(exists ? describeVideo(file) : "(video missing)")")
    }
    let store = loadStore()
    func choice(_ entry: NSDictionary?, _ surface: String) -> String {
        let content = (entry?[surface] as? NSDictionary)?["Content"] as? NSDictionary
        guard let first = (content?["Choices"] as? [NSDictionary])?.first else { return "-" }
        var config = "-"
        if let data = first["Configuration"] as? Data,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            config = "\(plist)".replacingOccurrences(of: "\n", with: " ")
        }
        return "\(first["Provider"] ?? "?") \(config)"
    }
    for (key, value) in store["Displays"] as! NSDictionary {
        let entry = value as? NSDictionary
        print("Display \(key) [\(entry?["Type"] ?? "-")]")
        for surface in ["Linked", "Desktop", "Idle"] where entry?[surface] != nil {
            print("  \(surface): \(choice(entry, surface))")
        }
    }
}

func thumbnail(for video: URL, to png: URL) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 800, height: 800)
    let sem = DispatchSemaphore(value: 0)
    generator.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { image, _, _ in
        if let image {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
        }
        sem.signal()
    }
    sem.wait()
}

func addEntries(to catalog: NSMutableDictionary, assetID: String, video: URL, thumb: URL) {
    let assets = catalog["assets"] as! NSMutableArray
    let asset: NSDictionary = [
        "accessibilityLabel": "Mosaic test video",
        "categories": [categoryID],
        "id": assetID,
        "includeInShuffle": false,
        "localizedNameKey": "Mosaic \(assetID.prefix(4))",
        "pointsOfInterest": [:] as NSDictionary,
        "preferredOrder": 0,
        "previewImage": thumb.absoluteString,
        "shotID": "MOSAIC_SPIKE",
        "showInTopLevel": true,
        "subcategories": [subcategoryID],
        "url-4K-SDR-240FPS": video.absoluteString,
        "videoGravity": "resize",
    ]
    assets.add(asset)
    let categories = catalog["categories"] as! NSMutableArray
    if !(categories as! [NSDictionary]).contains(where: { $0["id"] as? String == categoryID }) {
        let sub: NSDictionary = [
            "id": subcategoryID, "localizedNameKey": "Mosaic", "localizedDescriptionKey": "Mosaic",
            "preferredOrder": 0, "previewImage": thumb.absoluteString, "representativeAssetID": assetID,
        ]
        categories.add([
            "id": categoryID, "localizedNameKey": "Mosaic", "localizedDescriptionKey": "Mosaic",
            "preferredOrder": 100, "previewImage": thumb.absoluteString, "representativeAssetID": assetID,
            "subcategories": [sub],
        ] as NSDictionary)
    }
}

func add(video source: URL) {
    guard FileManager.default.fileExists(atPath: source.path) else { fail("no such video \(source.path)") }
    print("source: \(describeVideo(source))")
    let backup = makeBackup()
    let assetID = UUID().uuidString
    let video = videosDir.appendingPathComponent("\(assetID).mov")
    let thumb = thumbsDir.appendingPathComponent("\(assetID).png")
    try! FileManager.default.copyItem(at: source, to: video)
    thumbnail(for: video, to: thumb)
    try! "\(assetID)\n".write(to: backup.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
    // Write both: the manifest (what Native Aerials rebuilds its catalog
    // from, and what the agent reads with no override) and the override.
    let manifest = loadJSON(manifestURL)
    addEntries(to: manifest, assetID: assetID, video: video, thumb: thumb)
    writeJSON(manifest, to: manifestURL)
    let (active, override) = catalogURLs()
    if override {
        print("note: AerialManifestLocalPathOverride is set (\(active.path)); writing there too.")
        print("      Native Aerials may rebuild that file from the manifest and drop or keep the entry.")
        let catalog = loadJSON(active)
        addEntries(to: catalog, assetID: assetID, video: video, thumb: thumb)
        writeJSON(catalog, to: active)
    }
    restartAgent()
    print(assetID)
}

func set(assetID: String, display: String?) {
    guard FileManager.default.fileExists(atPath: videosDir.appendingPathComponent("\(assetID).mov").path)
    else { fail("no video for \(assetID) in \(videosDir.path)") }
    _ = makeBackup()
    let store = loadStore()
    let displays = store["Displays"] as! NSMutableDictionary
    let keys = display.map { [$0] } ?? (displays.allKeys as! [String])
    let config = try! PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
    let choice: NSDictionary = ["Configuration": config, "Files": [] as NSArray, "Provider": aerialProvider]
    let now = Date()
    // Each Space keeps its own Displays/<id> entry too. If only the top-level
    // one changes, WallpaperAgent copies the current Space's choice back over
    // it on start (seen in spike run 1), so write them all.
    let spaces = (store["Spaces"] as? NSDictionary)?.allValues.compactMap { ($0 as? NSDictionary)?["Displays"] as? NSDictionary } ?? []
    for key in keys {
        guard displays[key] is NSMutableDictionary else { fail("no display \(key) in Index.plist") }
        let entries = [displays[key]] + spaces.map { $0[key] }
        var count = 0
        for case let entry as NSMutableDictionary in entries {
            let surface = entry["Type"] as? String == "linked" ? "Linked" : "Desktop"
            let content = NSMutableDictionary(dictionary: ["Choices": [choice], "Shuffle": "$null"])
            entry[surface] = NSMutableDictionary(dictionary: ["Content": content, "LastSet": now, "LastUse": now])
            if entry["Type"] == nil { entry["Type"] = "individual" }
            count += 1
        }
        print("set \(key) to aerial \(assetID) in \(count) entries (top level + Spaces)")
    }
    let data = try! PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    try! data.write(to: storeURL, options: .atomic)
    restartAgent()
}

func restore(_ dir: URL) {
    let fm = FileManager.default
    func put(_ name: String, _ dest: URL) {
        let src = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { return }
        _ = try? fm.removeItem(at: dest)
        try! fm.copyItem(at: src, to: dest)
        print("restored \(dest.path)")
    }
    put("Index.plist", storeURL)
    put("manifest-entries.json", manifestURL)
    if let path = try? String(contentsOf: dir.appendingPathComponent("override-path.txt"), encoding: .utf8) {
        put("override-entries.json", URL(fileURLWithPath: path))
    }
    let added = (try? String(contentsOf: dir.appendingPathComponent("added.txt"), encoding: .utf8)) ?? ""
    for id in added.split(separator: "\n") {
        // Moved to the Trash, not deleted, in case the restore was a mistake.
        for url in [videosDir.appendingPathComponent("\(id).mov"), thumbsDir.appendingPathComponent("\(id).png")] {
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { print("trashed \(url.lastPathComponent)") }
        }
    }
    restartAgent()
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: show | add <video> | set <assetID> [--display <uuid>] | restore <dir>") }
args.removeFirst()
switch command {
case "show": show()
case "add":
    guard let path = args.first else { fail("add needs a video") }
    add(video: URL(fileURLWithPath: path).standardizedFileURL)
case "set":
    guard let id = args.first else { fail("set needs an asset ID") }
    var display: String?
    if let i = args.firstIndex(of: "--display"), i + 1 < args.count { display = args[i + 1] }
    set(assetID: id, display: display)
case "restore":
    guard let path = args.first else { fail("restore needs a backup dir") }
    restore(URL(fileURLWithPath: path))
default: fail("unknown command \(command)")
}

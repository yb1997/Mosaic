// Spike: can a third-party app give the lock screen / screen saver ("Idle")
// a still image that differs from the desktop?
//
//   swift lockspike.swift show
//   swift lockspike.swift set-idle <image> [--display <uuid>] [--dry-run]
//   swift lockspike.swift restore <backup Index.plist>
//
// Writes ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
// (private, undocumented format) and restarts WallpaperAgent.

import AppKit
import CoreGraphics

let home = FileManager.default.homeDirectoryForCurrentUser
let storeURL = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
let imageProvider = "com.apple.wallpaper.choice.image"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadStore() -> NSMutableDictionary {
    guard let data = try? Data(contentsOf: storeURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil),
          let dict = plist as? NSMutableDictionary
    else { fail("cannot read \(storeURL.path)") }
    // Refuse layouts we haven't seen, like Native Aerials does.
    for key in ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"] where dict[key] == nil {
        fail("Index.plist has no \(key); unknown layout, not touching it")
    }
    return dict
}

func decode(_ value: Any?) -> String {
    guard let data = value as? Data,
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
    else { return "-" }
    return "\(plist)".replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: "")
}

func describe(surface: NSDictionary?, name: String, indent: String) {
    guard let surface else { print("\(indent)\(name): (none)"); return }
    let content = surface["Content"] as? NSDictionary
    for case let choice as NSDictionary in content?["Choices"] as? NSArray ?? [] {
        let files = (choice["Files"] as? [NSDictionary] ?? []).compactMap { $0["relative"] as? String }
        print("\(indent)\(name): \(choice["Provider"] ?? "?") config=\(decode(choice["Configuration"])) files=\(files)")
    }
}

func describe(entry: NSDictionary, indent: String) {
    print("\(indent)Type: \(entry["Type"] ?? "-")")
    for surface in ["Linked", "Desktop", "Idle"] where entry[surface] != nil {
        describe(surface: entry[surface] as? NSDictionary, name: surface, indent: indent)
    }
}

func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "?" }
    return CFUUIDCreateString(nil, uuid) as String
}

func show() {
    print("Displays:")
    for screen in NSScreen.screens {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let main = CGDisplayIsMain(id) != 0 ? " (main)" : ""
        print("  \(screen.localizedName)\(main): \(displayUUID(id))")
    }
    let store = loadStore()
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        print("\(key):")
        describe(entry: store[key] as! NSDictionary, indent: "  ")
    }
    for key in ["Displays", "Spaces"] {
        let dict = store[key] as! NSDictionary
        print("\(key): \(dict.count == 0 ? "(empty)" : "")")
        for (k, v) in dict {
            print("  \(k):")
            if let v = v as? NSDictionary { describe(entry: v, indent: "    ") }
        }
    }
}

func imageSurface(for image: URL, optionsFrom template: NSDictionary?) -> NSMutableDictionary {
    let relative = image.absoluteString
    // Same shape as the Photos choice ({type, identifier}); "imageFile" and
    // "url" are strings found in WallpaperImageExtension.
    let config: [String: Any] = ["type": "imageFile", "url": ["relative": relative]]
    let configData = try! PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
    let choice: NSDictionary = [
        "Configuration": configData,
        "Files": [["relative": relative]],
        "Provider": imageProvider,
    ]
    let content = NSMutableDictionary(dictionary: ["Choices": [choice], "Shuffle": "$null"])
    // Reuse the desktop's option blob (placement etc.): a known-valid shape.
    if let options = (template?["Content"] as? NSDictionary)?["EncodedOptionValues"] {
        content["EncodedOptionValues"] = options
    }
    let now = Date()
    return NSMutableDictionary(dictionary: ["Content": content, "LastSet": now, "LastUse": now])
}

func backup() -> URL {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let dir = home.appendingPathComponent("backups/wallpaper-\(stamp.string(from: Date()))")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("Index.plist")
    try! FileManager.default.copyItem(at: storeURL, to: dest)
    return dest
}

func write(_ store: NSDictionary, to url: URL) {
    let data = try! PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    try! data.write(to: url, options: .atomic)
}

func restartAgent() {
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    kill.arguments = ["WallpaperAgent"]
    try? kill.run()
    kill.waitUntilExit()
    // launchd brings it back on demand; give it time to read (or rewrite) the store.
    Thread.sleep(forTimeInterval: 4)
}

func setIdle(image: URL, display: String?, dryRun: Bool) {
    guard FileManager.default.fileExists(atPath: image.path) else { fail("no such image \(image.path)") }
    let store = loadStore()
    let target: NSMutableDictionary
    if let display {
        let displays = store["Displays"] as! NSMutableDictionary
        // Unverified shape: mirror AllSpacesAndDisplays under the display's UUID.
        let global = store["AllSpacesAndDisplays"] as! NSDictionary
        let entry = (displays[display] as? NSMutableDictionary)
            ?? (global.mutableCopy() as! NSMutableDictionary)
        displays[display] = entry
        target = entry
    } else {
        target = store["AllSpacesAndDisplays"] as! NSMutableDictionary
    }
    let desktop = (target["Desktop"] ?? target["Linked"]) as? NSDictionary
    if target["Type"] as? String == "linked", let linked = target["Linked"] {
        // Split a linked choice so the desktop keeps what it showed.
        target["Desktop"] = linked
        target.removeObject(forKey: "Linked")
    }
    target["Type"] = "individual"
    target["Idle"] = imageSurface(for: image, optionsFrom: desktop)

    if dryRun {
        let out = URL(fileURLWithPath: "Index.dry-run.plist")
        write(store, to: out)
        print("dry run: wrote \(out.path)")
        return
    }
    let saved = backup()
    print("backup: \(saved.path)")
    write(store, to: storeURL)
    restartAgent()

    // Did WallpaperAgent keep our choice or write its own back?
    let after = loadStore()
    let entry = display.map { (after["Displays"] as! NSDictionary)[$0] as? NSDictionary } ?? after["AllSpacesAndDisplays"] as? NSDictionary
    let idle = ((entry?["Idle"] as? NSDictionary)?["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary]
    if idle?.first?["Provider"] as? String == imageProvider {
        print("ok: WallpaperAgent kept the image as Idle. Lock the Mac (ctrl-cmd-Q) and look.")
    } else {
        print("WallpaperAgent replaced the Idle choice:")
        describe(entry: entry ?? [:], indent: "  ")
        print("restore with: swift lockspike.swift restore \(saved.path)")
    }
}

func restore(from backupURL: URL) {
    guard let data = try? Data(contentsOf: backupURL),
          (try? PropertyListSerialization.propertyList(from: data, format: nil)) is NSDictionary
    else { fail("\(backupURL.path) is not a plist") }
    try! data.write(to: storeURL, options: .atomic)
    restartAgent()
    print("restored \(backupURL.path)")
}

var args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")
args.removeAll { $0 == "--dry-run" }
var display: String?
if let i = args.firstIndex(of: "--display"), i + 1 < args.count {
    display = args[i + 1]
    args.removeSubrange(i...i + 1)
}

switch (args.first, args.count) {
case ("show", 1):
    show()
case ("set-idle", 2):
    setIdle(image: URL(fileURLWithPath: args[1]).standardizedFileURL, display: display, dryRun: dryRun)
case ("restore", 2):
    restore(from: URL(fileURLWithPath: args[1]))
default:
    fail("usage: swift lockspike.swift show | set-idle <image> [--display <uuid>] [--dry-run] | restore <backup>")
}

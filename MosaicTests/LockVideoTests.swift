import Foundation
import Testing
@testable import Mosaic

/// macOS's wallpaper settings changes for lock screen videos, on a made-up
/// settings tree shaped like macOS 27.2's (never the real file).
struct LockVideoSettingsTests {
    private static let screen = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    private static let other = "02F963D7-7501-4779-AC30-7C3C2FAD7E73"

    private static func imageEntry(_ path: String, type: String? = "individual") -> NSMutableDictionary {
        let configuration = try! PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": "file://\(path)"]], format: .binary, options: 0)
        let choice: NSDictionary = ["Provider": SystemWallpaperStore.imageProvider, "Configuration": configuration, "Files": []]
        let entry = NSMutableDictionary(dictionary: [
            "Desktop": NSMutableDictionary(dictionary: ["Content": NSMutableDictionary(dictionary: ["Choices": [choice], "Shuffle": "$null"])]),
        ])
        if let type { entry["Type"] = type }
        return entry
    }

    /// Two screens at the top level and in two Spaces; `screen` is linked in one Space.
    private static func settings() -> NSMutableDictionary {
        let linked = imageEntry("/a.jpeg", type: "linked")
        linked["Linked"] = linked["Desktop"]
        linked["Desktop"] = nil
        return NSMutableDictionary(dictionary: [
            "Displays": NSMutableDictionary(dictionary: [screen: imageEntry("/a.jpeg"), other: imageEntry("/b.jpeg")]),
            "Spaces": NSMutableDictionary(dictionary: [
                "S1": NSMutableDictionary(dictionary: ["Displays": NSMutableDictionary(dictionary: [screen: imageEntry("/a.jpeg", type: nil)])]),
                "S2": NSMutableDictionary(dictionary: ["Displays": NSMutableDictionary(dictionary: [screen: linked, other: imageEntry("/b.jpeg")])]),
            ]),
        ])
    }

    @Test func aerialGoesInEveryEntryForTheScreen() throws {
        let store = Self.settings()
        #expect(SystemWallpaperStore.aerialAsset(on: Self.screen, in: store) == nil)
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        #expect(SystemWallpaperStore.aerialAsset(on: Self.screen, in: store) == "ASSET")
        #expect(SystemWallpaperStore.aerialAsset(on: Self.other, in: store) == nil)

        // The linked Space keeps its type and gets the aerial as its Linked choice.
        let s2 = try #require(((store["Spaces"] as? NSDictionary)?["S2"] as? NSDictionary)?["Displays"] as? NSDictionary)
        let linked = try #require(s2[Self.screen] as? NSDictionary)
        #expect(linked["Type"] as? String == "linked")
        #expect(linked["Desktop"] == nil)
        // An entry without a type gets one.
        let s1 = try #require(((store["Spaces"] as? NSDictionary)?["S1"] as? NSDictionary)?["Displays"] as? NSDictionary)
        #expect((s1[Self.screen] as? NSDictionary)?["Type"] as? String == "individual")

        // It survives a round trip through the real file format.
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        let parsed = try #require(SystemWallpaperStore.parse(data))
        #expect(SystemWallpaperStore.aerialAsset(on: Self.screen, in: parsed) == "ASSET")
    }

    @Test func aSpaceThatDisagreesMeansNoAerial() throws {
        let store = Self.settings()
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        let s1 = try #require(((store["Spaces"] as? NSDictionary)?["S1"] as? NSDictionary)?["Displays"] as? NSMutableDictionary)
        s1[Self.screen] = Self.imageEntry("/a.jpeg")
        #expect(SystemWallpaperStore.aerialAsset(on: Self.screen, in: store) == nil)
    }

    @Test func pictureGoesBackInEveryEntry() throws {
        let store = Self.settings()
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        #expect(SystemWallpaperStore.setImage(URL(fileURLWithPath: "/c.heic"), on: Self.screen, in: store))
        #expect(SystemWallpaperStore.aerialAsset(on: Self.screen, in: store) == nil)
        let top = try #require((store["Displays"] as? NSDictionary)?[Self.screen] as? NSDictionary)
        let choice = try #require((((top["Desktop"] as? NSDictionary)?["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary])?.first)
        #expect(choice["Provider"] as? String == SystemWallpaperStore.imageProvider)
        let configuration = try #require(choice["Configuration"] as? Data)
        let settings = try #require(try PropertyListSerialization.propertyList(from: configuration, format: nil) as? NSDictionary)
        #expect((settings["url"] as? NSDictionary)?["relative"] as? String == "file:///c.heic")
    }

    private static func idleAsset(_ store: NSDictionary, space: String?) -> String? {
        let displays = space.map { ((store["Spaces"] as? NSDictionary)?[$0] as? NSDictionary)?["Displays"] as? NSDictionary }
            ?? (store["Displays"] as? NSDictionary)
        guard let entry = displays?[Self.screen] as? NSDictionary,
              let choice = (((entry["Idle"] as? NSDictionary)?["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary])?.first,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return nil }
        return (configuration["assetID"] as? String) ?? ((configuration["url"] as? NSDictionary)?["relative"] as? String)
    }

    /// An idle lock shows the screen saver choice, so the aerial goes there
    /// too, and what was there comes back when the video stops.
    @Test func screenSaverShowsTheVideoAndComesBack() throws {
        let store = Self.settings()
        let top = try #require((store["Displays"] as? NSDictionary)?[Self.screen] as? NSMutableDictionary)
        top["Idle"] = (Self.imageEntry("/saver.jpeg")["Desktop"] as? NSDictionary)
        #expect(!SystemWallpaperStore.screenSaverShows("ASSET", on: Self.screen, in: store))

        let before = SystemWallpaperStore.screenSavers(on: Self.screen, in: store, ignoring: ["ASSET"])
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        #expect(SystemWallpaperStore.screenSaverShows("ASSET", on: Self.screen, in: store))
        #expect(Self.idleAsset(store, space: nil) == "ASSET")
        #expect(Self.idleAsset(store, space: "S1") == "ASSET")
        // A linked entry has no separate screen saver choice.
        let s2 = try #require(((store["Spaces"] as? NSDictionary)?["S2"] as? NSDictionary)?["Displays"] as? NSDictionary)
        #expect((s2[Self.screen] as? NSDictionary)?["Idle"] == nil)
        // Another screen is untouched.
        #expect(!SystemWallpaperStore.screenSaverShows("ASSET", on: Self.other, in: store))

        // Switching to another video doesn't save Mosaic's own aerial.
        let again = SystemWallpaperStore.screenSavers(on: Self.screen, in: store, ignoring: ["ASSET"])
        let saved = SystemWallpaperStore.mergeSaved(before, again)
        #expect(SystemWallpaperStore.setAerial("OTHER", on: Self.screen, in: store))

        #expect(SystemWallpaperStore.restoreScreenSavers(saved, replacing: ["ASSET", "OTHER"], on: Self.screen, in: store))
        #expect(Self.idleAsset(store, space: nil) == "file:///saver.jpeg")
        // S1 had no screen saver choice of its own, so it has none again.
        let s1 = try #require(((store["Spaces"] as? NSDictionary)?["S1"] as? NSDictionary)?["Displays"] as? NSDictionary)
        #expect((s1[Self.screen] as? NSDictionary)?["Idle"] == nil)
        #expect(!SystemWallpaperStore.restoreScreenSavers(saved, replacing: ["ASSET", "OTHER"], on: Self.screen, in: store))
    }

    /// A screen saver changed in System Settings while the video was on stays.
    @Test func screenSaverChangedElsewhereIsKept() throws {
        let store = Self.settings()
        let saved = SystemWallpaperStore.screenSavers(on: Self.screen, in: store, ignoring: ["ASSET"])
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        let top = try #require((store["Displays"] as? NSDictionary)?[Self.screen] as? NSMutableDictionary)
        top["Idle"] = (Self.imageEntry("/new.jpeg")["Desktop"] as? NSDictionary)
        #expect(SystemWallpaperStore.restoreScreenSavers(saved, replacing: ["ASSET"], on: Self.screen, in: store))
        #expect(Self.idleAsset(store, space: nil) == "file:///new.jpeg")
        #expect(Self.idleAsset(store, space: "S1") == nil)
    }

    /// A screen with no video shows its picture on an idle lock while another
    /// screen plays one, and its screen saver comes back afterwards.
    @Test func otherScreensScreenSaverShowsItsPictureAndComesBack() throws {
        let store = Self.settings()
        let pictures = URL(fileURLWithPath: "/Mosaic/Images")
        let image = pictures.appendingPathComponent("two words.jpeg")
        let top = try #require((store["Displays"] as? NSDictionary)?[Self.screen] as? NSMutableDictionary)
        top["Idle"] = (Self.imageEntry("/saver.jpeg")["Desktop"] as? NSDictionary)
        #expect(!SystemWallpaperStore.screenSaverShows(image: image, on: Self.screen, in: store))

        let saved = SystemWallpaperStore.screenSavers(on: Self.screen, in: store, ignoring: [], picturesIn: pictures)
        #expect(SystemWallpaperStore.setScreenSaver(image: image, on: Self.screen, in: store))
        #expect(SystemWallpaperStore.screenSaverShows(image: image, on: Self.screen, in: store))
        #expect(Self.idleAsset(store, space: "S1") == image.absoluteString)
        // Only the screen saver changes, and only on this screen.
        #expect(SystemWallpaperStore.screenSaverShows(image: image, on: Self.other, in: store) == false)
        let choice = try #require((((top["Desktop"] as? NSDictionary)?["Content"] as? NSDictionary)?["Choices"] as? [NSDictionary])?.first)
        let data = try #require(choice["Configuration"] as? Data)
        let configuration = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
        #expect((configuration["url"] as? NSDictionary)?["relative"] as? String == "file:///a.jpeg")

        // Mosaic's own picture is never what gets saved.
        let again = try #require(SystemWallpaperStore.screenSavers(on: Self.screen, in: store, ignoring: [], picturesIn: pictures))
        let choices = try #require(try PropertyListSerialization.propertyList(from: again, format: nil) as? NSDictionary)
        #expect(choices.count == 0)

        #expect(SystemWallpaperStore.restoreScreenSavers(saved, replacing: [], picturesIn: pictures, on: Self.screen, in: store))
        #expect(Self.idleAsset(store, space: nil) == "file:///saver.jpeg")
        #expect(Self.idleAsset(store, space: "S1") == nil)
    }

    /// The LG's case: a Mosaic video left in a screen saver with nothing saved.
    @Test func leftoverVideoInAScreenSaverIsFound() throws {
        let store = Self.settings()
        #expect(!SystemWallpaperStore.screenSaverShowsAny(of: ["ASSET"], on: Self.screen, in: store))
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        #expect(SystemWallpaperStore.screenSaverShowsAny(of: ["ASSET"], on: Self.screen, in: store))
        #expect(!SystemWallpaperStore.screenSaverShowsAny(of: ["OTHER"], on: Self.screen, in: store))
        #expect(!SystemWallpaperStore.screenSaverShowsAny(of: ["ASSET"], on: Self.other, in: store))
    }

    /// A wallpaper NSWorkspace couldn't set back survives a lock video, in
    /// every entry, including one for a Space made while the video was on.
    @Test func wallpaperComesBackAfterTheVideo() throws {
        let store = Self.settings()
        let saved = SystemWallpaperStore.wallpapers(on: Self.screen, in: store, ignoring: ["ASSET"])
        #expect(SystemWallpaperStore.savedPicture(saved) == URL(string: "file:///a.jpeg"))
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        #expect(SystemWallpaperStore.entryCount(on: Self.screen, in: store) == 3)

        let spaces = try #require(store["Spaces"] as? NSMutableDictionary)
        let aerial = try #require((store["Displays"] as? NSDictionary)?[Self.screen] as? NSMutableDictionary)
        spaces["S3"] = NSMutableDictionary(dictionary: ["Displays": NSMutableDictionary(dictionary: [Self.screen: aerial.mutableCopy()])])
        #expect(SystemWallpaperStore.entryCount(on: Self.screen, in: store) == 4)
        // Saving again while it plays must not replace the real one.
        let again = SystemWallpaperStore.wallpapers(on: Self.screen, in: store, ignoring: ["ASSET"])
        let merged = SystemWallpaperStore.mergeSaved(saved, again)

        #expect(SystemWallpaperStore.restoreWallpapers(merged, replacing: ["ASSET"], on: Self.screen, in: store))
        let after = try #require(SystemWallpaperStore.wallpapers(on: Self.screen, in: store, ignoring: ["ASSET"]))
        let choices = try #require(try PropertyListSerialization.propertyList(from: after, format: nil) as? NSDictionary)
        #expect(choices.count == 4)
        #expect(SystemWallpaperStore.savedPicture(after) == URL(string: "file:///a.jpeg"))
    }

    @Test func nothingSavedMeansNothingRestored() {
        let store = Self.settings()
        #expect(SystemWallpaperStore.setAerial("ASSET", on: Self.screen, in: store))
        #expect(!SystemWallpaperStore.restoreWallpapers(nil, replacing: ["ASSET"], on: Self.screen, in: store))
        #expect(SystemWallpaperStore.aerialAsset(on: Self.screen, in: store) == "ASSET")
    }

    @Test func mosaicOnlyTakesAnOverrideNobodyElseHolds() {
        let own = AerialCatalog.ownCatalogURL.standardizedFileURL
        let foreign = URL(fileURLWithPath: "/other/entries.json")
        #expect(AerialCatalog.needsOwnOverride(current: nil, fileExists: false))
        #expect(!AerialCatalog.needsOwnOverride(current: foreign, fileExists: true))
        // Left behind by an app that was removed.
        #expect(AerialCatalog.needsOwnOverride(current: foreign, fileExists: false))
        #expect(!AerialCatalog.needsOwnOverride(current: own, fileExists: true))
    }

    @Test func unknownScreenIsLeftAlone() {
        let store = Self.settings()
        #expect(!SystemWallpaperStore.setAerial("ASSET", on: "NOT-CONNECTED", in: store))
        #expect(SystemWallpaperStore.parse(Data("not a plist".utf8)) == nil)
    }

    @Test func assetIDsAreStableUUIDs() throws {
        let video = VideoFile(sourceHash: String(repeating: "ab", count: 32), format: .standard)
        let id = AerialCatalog.assetID(for: video, scaling: .fill)
        #expect(UUID(uuidString: id) != nil)
        #expect(id == AerialCatalog.assetID(for: video, scaling: .fill))
        #expect(id != AerialCatalog.assetID(for: video, scaling: .fit))
        let other = VideoFile(sourceHash: String(repeating: "cd", count: 32), format: .standard)
        #expect(id != AerialCatalog.assetID(for: other, scaling: .fill))
    }

    /// macOS rejects the whole catalog when a category names a missing asset,
    /// so removing the asset a category shows must move the category on.
    @Test func categoryNeverNamesARemovedAsset() {
        func asset(_ id: String, ours: Bool) -> NSDictionary {
            ["id": id, "categories": [ours ? AerialCatalog.categoryID : "APPLE"], "previewImage": "file:///\(id).png"]
        }
        let catalog = NSMutableDictionary(dictionary: [
            "assets": NSMutableArray(array: [asset("APPLE-1", ours: false), asset("A", ours: true), asset("B", ours: true)]),
            "categories": NSMutableArray(array: [["id": "APPLE", "representativeAssetID": "APPLE-1"] as NSDictionary]),
        ])
        AerialCatalog.rebuildCategory(in: catalog)
        #expect(AerialCatalog.hasValidCategory(catalog))

        // What broke on this Mac: A removed, the category still naming it.
        catalog["assets"] = NSMutableArray(array: [asset("APPLE-1", ours: false), asset("B", ours: true)])
        #expect(!AerialCatalog.hasValidCategory(catalog))
        AerialCatalog.rebuildCategory(in: catalog)
        #expect(AerialCatalog.hasValidCategory(catalog))
        let ours = (catalog["categories"] as? [NSDictionary])?.first { $0["id"] as? String == AerialCatalog.categoryID }
        #expect(ours?["representativeAssetID"] as? String == "B")
        #expect(((ours?["subcategories"] as? [NSDictionary])?.first)?["representativeAssetID"] as? String == "B")

        // No Mosaic assets left: no Mosaic category, Apple's untouched.
        catalog["assets"] = NSMutableArray(array: [asset("APPLE-1", ours: false)])
        AerialCatalog.rebuildCategory(in: catalog)
        #expect(AerialCatalog.hasValidCategory(catalog))
        #expect((catalog["categories"] as? [NSDictionary])?.map { $0["id"] as? String } == ["APPLE"])
    }

    @Test func lockCopyIsNotItselfAVideoWallpaper() {
        let video = VideoFile(sourceHash: String(repeating: "ab", count: 32), format: .standard)
        #expect(video.aerialName == "\(video.sourceHash)-30-balanced-aerial.mov")
        #expect(!VideoFile.isVideo(video.aerialName))
    }
}

struct ProcessLookupTests {
    /// The kernel lookup finds what pgrep finds, without spawning anything.
    @Test func findsTheSameProcessesAsPgrep() throws {
        for name in ["launchd", "WallpaperAgent", "NoSuchProcessName"] {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", "-u", String(getuid()), name]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            try pgrep.run()
            pgrep.waitUntilExit()
            let expected = Set(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
                .split(separator: "\n").compactMap { pid_t($0) })
            #expect(Set(SystemWallpaperStore.pids(of: name)) == expected, "\(name)")
        }
    }
}

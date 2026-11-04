import AppKit
import Foundation
import Testing
@testable import Mosaic

/// A store on a throwaway folder and defaults suite, removed afterwards.
@MainActor
final class Sandbox {
    let folder: URL
    let suiteName = "MosaicTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicTests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suiteName)!
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    var images: URL { folder.appendingPathComponent("Images", isDirectory: true) }

    func store(displays: [Display] = []) -> WallpaperStore {
        WallpaperStore(directory: folder, defaults: defaults, displays: displays)
    }

    func writeState(_ json: String) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent("state.json"))
    }

    func writeProfiles(_ json: String) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent("profiles.json"))
    }

    func addImage(_ name: String, bytes: Data = Data("image".utf8)) throws {
        try bytes.write(to: images.appendingPathComponent(name))
    }

    var imageFiles: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [])
    }
}

@MainActor
struct StoreTests {
    @Test func usesItsOwnFolder() {
        let sandbox = Sandbox()
        let store = sandbox.store()
        #expect(store.directory == sandbox.folder)
        #expect(store.imagesDirectory != WallpaperStore.defaultDirectory.appendingPathComponent("Images"))
    }

    @Test func appIsInTestMode() {
        #expect(MosaicApp.isRunningTests)
    }

    // MARK: Active profile

    @Test func activeProfileMatchesCurrentChoicesExactly() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.addImage("b.png")
        try sandbox.writeState(#"{"D1": {"desktop": "a.png"}}"#)
        try sandbox.writeProfiles("""
            [{"name": "Other", "screens": {"D1": {"desktop": "b.png"}}},
             {"name": "Match", "screens": {"D1": {"desktop": "a.png"}}}]
            """)
        #expect(sandbox.store().activeProfile?.name == "Match")
    }

    @Test func noActiveProfileWhenAnySettingDiffers() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.writeState(#"{"D1": {"desktop": "a.png", "lockSameAsDesktop": true}}"#)
        try sandbox.writeProfiles(#"[{"name": "Near", "screens": {"D1": {"desktop": "a.png"}}}]"#)
        #expect(sandbox.store().activeProfile == nil)
    }

    // MARK: Image cleanup at launch

    @Test func launchKeepsUsedImagesAndDeletesTheRest() throws {
        let sandbox = Sandbox()
        for name in ["current.png", "profile.png", "stray.png"] { try sandbox.addImage(name) }
        try sandbox.writeState(#"{"D1": {"desktop": "current.png"}}"#)
        try sandbox.writeProfiles(#"[{"name": "P", "screens": {"D2": {"lock": "profile.png"}}}]"#)
        _ = sandbox.store()
        #expect(sandbox.imageFiles == ["current.png", "profile.png"])
    }

    @Test func unreadableProfilesKeepAllImages() throws {
        let sandbox = Sandbox()
        for name in ["current.png", "profile-only.png"] { try sandbox.addImage(name) }
        try sandbox.writeState(#"{"D1": {"desktop": "current.png"}}"#)
        try sandbox.writeProfiles("not json")
        _ = sandbox.store()
        #expect(sandbox.imageFiles == ["current.png", "profile-only.png"])
    }

    // MARK: Profile names

    @Test func duplicateNamesAreRefusedIgnoringCaseAndSpaces() {
        let sandbox = Sandbox()
        let store = sandbox.store()
        store.saveProfile(named: "Work")
        #expect(store.isProfileNameTaken("work"))
        #expect(store.isProfileNameTaken("  WORK "))
        #expect(!store.isProfileNameTaken("Home"))
        store.saveProfile(named: " work ")
        #expect(store.profiles.map(\.name) == ["Work"])
    }

    @Test func renameChecksOtherProfilesOnly() throws {
        let sandbox = Sandbox()
        let store = sandbox.store()
        store.saveProfile(named: "Work")
        store.saveProfile(named: "Home")
        let work = try #require(store.profiles.first { $0.name == "Work" })
        let home = try #require(store.profiles.first { $0.name == "Home" })

        store.rename(work, to: "WORK")
        #expect(store.profiles.first { $0.id == work.id }?.name == "WORK")

        store.rename(home, to: "work")
        #expect(store.profiles.first { $0.id == home.id }?.name == "Home")
    }

    @Test func existingDuplicateNamesStillLoad() throws {
        let sandbox = Sandbox()
        try sandbox.writeProfiles(#"[{"name": "Same", "screens": {}}, {"name": "Same", "screens": {}}]"#)
        #expect(sandbox.store().profiles.count == 2)
    }
}

/// Tests that need a real screen to build a `Display` from.
@MainActor
@Suite(.enabled(if: !NSScreen.screens.isEmpty, "Needs a screen"))
struct StoreDisplayTests {
    private func testDisplay() -> Display {
        Display(id: "TEST-DISPLAY", name: "Test Display", isMain: true, screen: NSScreen.screens[0])
    }

    private func waitForImports(_ store: WallpaperStore, _ display: Display) async throws {
        for _ in 0..<250 {
            if !Slot.allCases.contains(where: { store.isImporting($0, display: display) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Import didn't finish")
    }

    @Test func pendingUndoKeepsTheClearedImage() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.writeState(#"{"TEST-DISPLAY": {"desktop": "a.png"}}"#)
        let display = testDisplay()
        let store = sandbox.store(displays: [display])

        store.clear(.desktop, display: display)
        #expect(store.wallpapers(for: display).desktop == nil)
        #expect(sandbox.imageFiles == ["a.png"])

        store.undo()
        #expect(store.wallpapers(for: display).desktop == "a.png")

        store.clear(.desktop, display: display)
        store.dismissUndo()
        #expect(sandbox.imageFiles.isEmpty)
    }

    @Test func importInProgressIsNotCleanedUp() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.writeState(#"{"TEST-DISPLAY": {"lock": "a.png"}}"#)
        let display = testDisplay()
        let store = sandbox.store(displays: [display])

        let temporary = store.beginImport(slot: .desktop, displayID: display.id, fileExtension: "png")
        try Data("copying".utf8).write(to: temporary)
        store.clear(.lock, display: display)
        store.dismissUndo()
        #expect(sandbox.imageFiles == [temporary.lastPathComponent])

        store.finishImport(temporary, error: CocoaError(.fileReadUnknown), sourceName: "x.png", slot: .desktop, displayID: display.id)
        #expect(sandbox.imageFiles.isEmpty)
        #expect(store.lastError != nil)
        store.dismissError()
        #expect(store.lastError == nil)
    }

    @Test func sameImageIsStoredOnce() async throws {
        let sandbox = Sandbox()
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let jpg = sandbox.folder.appendingPathComponent("photo.jpg")
        let jpeg = sandbox.folder.appendingPathComponent("copy.JPEG")
        try bytes.write(to: jpg)
        try bytes.write(to: jpeg)

        store.setImage(from: jpg, slot: .desktop, display: display)
        try await waitForImports(store, display)
        store.setImage(from: jpeg, slot: .lock, display: display)
        try await waitForImports(store, display)

        let wallpapers = store.wallpapers(for: display)
        let name = try #require(wallpapers.desktop)
        #expect(wallpapers.lock == name)
        #expect(sandbox.imageFiles == [name])
        let hash = try #require(name.split(separator: ".").first)
        #expect(hash.count == 64 && hash.allSatisfy(\.isHexDigit))

        // Clearing one slot keeps the shared file; clearing both removes it.
        store.clear(.lock, display: display)
        store.dismissUndo()
        #expect(sandbox.imageFiles == [name])
        store.clear(.desktop, display: display)
        store.dismissUndo()
        #expect(sandbox.imageFiles.isEmpty)
    }

    @Test func clearingTheDesktopTellsTheEngine() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.addImage("b.png")
        try sandbox.writeState(#"{"TEST-DISPLAY": {"desktop": "a.png", "lock": "b.png"}}"#)
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        var cleared: [String] = []
        store.onDesktopCleared = { cleared.append($0) }

        store.clear(.lock, display: display)
        #expect(cleared.isEmpty)
        store.clear(.desktop, display: display)
        #expect(cleared == [display.id])
    }
}

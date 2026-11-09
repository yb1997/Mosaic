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

    /// Not just at launch: later cleanups, and later launches, keep them too.
    @Test func unreadableProfilesKeepImagesAfterLaterChanges() throws {
        let sandbox = Sandbox()
        for name in ["current.png", "profile-only.png"] { try sandbox.addImage(name) }
        try sandbox.writeState(#"{"D1": {"desktop": "current.png"}}"#)
        try sandbox.writeProfiles("not json")
        let store = sandbox.store()
        store.saveProfile(named: "New")
        store.delete(try #require(store.profiles.first))
        #expect(sandbox.imageFiles == ["current.png", "profile-only.png"])

        _ = sandbox.store()
        #expect(sandbox.imageFiles == ["current.png", "profile-only.png"])
        let copy = sandbox.folder.appendingPathComponent("profiles.json.unreadable")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "not json")
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

    @Test func importFinishingAfterProfileApplyIsDropped() async throws {
        let sandbox = Sandbox()
        try sandbox.addImage("profile.png")
        try sandbox.writeProfiles(#"[{"name": "P", "screens": {"TEST-DISPLAY": {"desktop": "profile.png"}}}]"#)
        let display = testDisplay()
        let store = sandbox.store(displays: [display])

        let temporary = store.beginImport(slot: .desktop, displayID: display.id, fileExtension: "png")
        try Data("copied".utf8).write(to: temporary)
        store.apply(try #require(store.profiles.first))
        store.finishImport(temporary, error: nil, sourceName: "x.png", slot: .desktop, displayID: display.id)
        for _ in 0..<100 where sandbox.imageFiles != ["profile.png"] { try await Task.sleep(for: .milliseconds(20)) }

        #expect(store.wallpapers(for: display).desktop == "profile.png")
        #expect(sandbox.imageFiles == ["profile.png"])
        #expect(!store.isImporting(.desktop, display: display))
    }

    @Test func lastPickedImageWinsWhenCopiesFinishOutOfOrder() async throws {
        let sandbox = Sandbox()
        let display = testDisplay()
        let store = sandbox.store(displays: [display])

        let first = store.beginImport(slot: .desktop, displayID: display.id, fileExtension: "png")
        let second = store.beginImport(slot: .desktop, displayID: display.id, fileExtension: "png")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        store.finishImport(second, error: nil, sourceName: "b.png", slot: .desktop, displayID: display.id)
        for _ in 0..<100 where store.isImporting(.desktop, display: display) { try await Task.sleep(for: .milliseconds(20)) }
        let chosen = store.wallpapers(for: display).desktop
        store.finishImport(first, error: nil, sourceName: "a.png", slot: .desktop, displayID: display.id)
        try await Task.sleep(for: .milliseconds(300))

        #expect(chosen != nil)
        #expect(store.wallpapers(for: display).desktop == chosen)
        #expect(sandbox.imageFiles == [try #require(chosen)])
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

    // MARK: Tile menu

    private func twoDisplays() -> (Display, Display, Display) {
        let screen = NSScreen.screens[0]
        return (Display(id: "D1", name: "One", isMain: true, screen: screen),
                Display(id: "D2", name: "Two", isMain: false, screen: screen),
                Display(id: "D3", name: "Three", isMain: false, screen: screen))
    }

    @Test func useOnAllScreensCopiesTheSlotAndUndoesAtOnce() throws {
        let sandbox = Sandbox()
        for name in ["a.png", "b.png", "old.png"] { try sandbox.addImage(name) }
        try sandbox.writeState("""
            {"D1": {"desktop": "a.png", "lock": "b.png"},
             "D2": {"desktop": "old.png"},
             "D3": {"lockSameAsDesktop": true}}
            """)
        let (one, two, three) = twoDisplays()
        let store = sandbox.store(displays: [one, two, three])

        store.useOnAllScreens(.lock, from: one)
        #expect(store.wallpapers(for: two).lock == "b.png")
        #expect(store.wallpapers(for: two).desktop == "old.png")
        #expect(store.wallpapers(for: three).lock == "b.png")
        #expect(store.wallpapers(for: three).lockSameAsDesktop == false)
        #expect(store.undoable != nil)

        store.undo()
        #expect(store.wallpapers(for: two) == { var e = ScreenWallpapers(); e.desktop = "old.png"; return e }())
        #expect(store.wallpapers(for: three).lockSameAsDesktop == true)
        #expect(store.wallpapers(for: three).lock == nil)
    }

    @Test func copyReplacesOnlyTheTarget() throws {
        let sandbox = Sandbox()
        for name in ["a.png", "old.png"] { try sandbox.addImage(name) }
        try sandbox.writeState(#"{"D1": {"desktop": "a.png"}, "D2": {"desktop": "old.png"}, "D3": {"desktop": "old.png"}}"#)
        let (one, two, three) = twoDisplays()
        let store = sandbox.store(displays: [one, two, three])

        store.copy(.desktop, from: one, to: two)
        #expect(store.wallpapers(for: two).desktop == "a.png")
        #expect(store.wallpapers(for: three).desktop == "old.png")
        // The replaced image stays while Undo is offered.
        #expect(sandbox.imageFiles == ["a.png", "old.png"])
    }

    @Test func emptySlotCopiesNothing() throws {
        let sandbox = Sandbox()
        let (one, two, _) = twoDisplays()
        let store = sandbox.store(displays: [one, two])
        store.useOnAllScreens(.desktop, from: one)
        #expect(store.screens.isEmpty)
        #expect(store.undoable == nil)
    }

    @Test func linkedLockSlotHasNoImageToCopy() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.addImage("b.png")
        try sandbox.writeState(#"{"D1": {"desktop": "a.png", "lock": "b.png", "lockSameAsDesktop": true}}"#)
        let (one, two, _) = twoDisplays()
        let store = sandbox.store(displays: [one, two])
        #expect(store.image(.lock, on: one) == nil)
        store.copy(.lock, from: one, to: two)
        #expect(store.wallpapers(for: two).lock == nil)
    }

    @Test func swapNeedsTwoDifferentImages() throws {
        let sandbox = Sandbox()
        for name in ["a.png", "b.png"] { try sandbox.addImage(name) }
        try sandbox.writeState("""
            {"D1": {"desktop": "a.png", "lock": "b.png"},
             "D2": {"desktop": "a.png"},
             "D3": {"desktop": "a.png", "lock": "b.png", "lockSameAsDesktop": true}}
            """)
        let (one, two, three) = twoDisplays()
        let store = sandbox.store(displays: [one, two, three])
        #expect(!store.canSwap(on: two))
        #expect(!store.canSwap(on: three))

        store.swapDesktopAndLock(on: one)
        #expect(store.wallpapers(for: one).desktop == "b.png")
        #expect(store.wallpapers(for: one).lock == "a.png")
        store.undo()
        #expect(store.wallpapers(for: one).desktop == "a.png")

        store.swapDesktopAndLock(on: two)
        #expect(store.wallpapers(for: two).desktop == "a.png")
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

    // MARK: Scaling

    @Test func scalingIsSavedAndReloaded() throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.writeState(#"{"D1": {"desktop": "a.png"}}"#)
        let (one, _, _) = twoDisplays()
        let store = sandbox.store(displays: [one])
        var changes = 0
        store.onChange = { changes += 1 }

        store.setScaling(.fit, .desktop, display: one)
        #expect(store.wallpapers(for: one).desktopScaling == .fit)
        #expect(store.wallpapers(for: one).lockScaling == .fill)
        #expect(changes == 1)
        // Picking the scaling it already has changes nothing.
        store.setScaling(.fit, .desktop, display: one)
        #expect(changes == 1)

        let reloaded = sandbox.store(displays: [one])
        #expect(reloaded.wallpapers(for: one).desktopScaling == .fit)
    }

    @Test func copyAndSwapCarryTheScaling() throws {
        let sandbox = Sandbox()
        for name in ["a.png", "b.png"] { try sandbox.addImage(name) }
        try sandbox.writeState("""
            {"D1": {"desktop": "a.png", "lock": "b.png", "desktopScaling": "center", "lockScaling": "stretch"},
             "D2": {"desktop": "b.png", "desktopScaling": "fit"}}
            """)
        let (one, two, three) = twoDisplays()
        let store = sandbox.store(displays: [one, two, three])

        store.useOnAllScreens(.desktop, from: one)
        #expect(store.wallpapers(for: two).desktopScaling == .center)
        #expect(store.wallpapers(for: three).desktopScaling == .center)
        store.undo()
        #expect(store.wallpapers(for: two).desktopScaling == .fit)

        store.swapDesktopAndLock(on: one)
        #expect(store.wallpapers(for: one).desktopScaling == .stretch)
        #expect(store.wallpapers(for: one).lockScaling == .center)
    }

    @Test func linkedLockUsesTheDesktopScaling() {
        var entry = ScreenWallpapers()
        entry.desktop = "a.png"
        entry.lock = "b.png"
        entry.desktopScaling = .fit
        entry.lockScaling = .center
        #expect(entry.effectiveLockScaling == .center)
        entry.lockSameAsDesktop = true
        #expect(entry.effectiveLockScaling == .fit)
    }
}

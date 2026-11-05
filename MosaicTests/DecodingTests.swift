import Foundation
import Testing
@testable import Mosaic

/// Saved files from older versions must keep loading.
struct DecodingTests {
    @Test func screenWithoutLockSwitchDefaultsToOff() throws {
        let json = #"{"desktop": "a.png", "lock": "b.png"}"#
        let screen = try JSONDecoder().decode(ScreenWallpapers.self, from: Data(json.utf8))
        #expect(screen.desktop == "a.png")
        #expect(screen.lock == "b.png")
        #expect(screen.lockSameAsDesktop == false)
        #expect(screen.effectiveLock == "b.png")
    }

    @Test func emptyScreenDecodes() throws {
        let screen = try JSONDecoder().decode(ScreenWallpapers.self, from: Data("{}".utf8))
        #expect(screen == ScreenWallpapers())
    }

    @Test func lockSameAsDesktopHidesLockImage() throws {
        let json = #"{"desktop": "a.png", "lock": "b.png", "lockSameAsDesktop": true}"#
        let screen = try JSONDecoder().decode(ScreenWallpapers.self, from: Data(json.utf8))
        #expect(screen.lock == "b.png")
        #expect(screen.effectiveLock == nil)
    }

    @Test func profileWithMissingFieldsGetsDefaults() throws {
        let profiles = try JSONDecoder().decode([Profile].self, from: Data("[{}]".utf8))
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Profile")
        #expect(profiles[0].screens.isEmpty)
    }

    @Test func profileKeepsItsID() throws {
        let id = UUID()
        let json = #"[{"id": "\#(id.uuidString)", "name": "Work", "screens": {"D1": {"desktop": "a.png"}}}]"#
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(json.utf8))
        #expect(profiles[0].id == id)
        #expect(profiles[0].name == "Work")
        #expect(profiles[0].screens["D1"]?.desktop == "a.png")
    }

    @Test func screenWithoutScalingFills() throws {
        let json = #"{"desktop": "a.png", "lock": "b.png"}"#
        let screen = try JSONDecoder().decode(ScreenWallpapers.self, from: Data(json.utf8))
        #expect(screen.desktopScaling == .fill)
        #expect(screen.lockScaling == .fill)
    }

    @Test func unknownScalingFallsBackToFill() throws {
        let json = #"{"desktop": "a.png", "desktopScaling": "tile", "lockScaling": "fit"}"#
        let screen = try JSONDecoder().decode(ScreenWallpapers.self, from: Data(json.utf8))
        #expect(screen.desktopScaling == .fill)
        #expect(screen.lockScaling == .fit)
    }
}

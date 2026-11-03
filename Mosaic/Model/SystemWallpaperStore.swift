import Foundation

/// PRIVATE: macOS's own wallpaper settings file, read and written directly.
/// See docs/PRIVATE_APIS.md. Used only to put back a wallpaper that isn't one
/// of ours (a Photos picture, an aerial, Apple's dynamic wallpapers), which
/// NSWorkspace can neither read back nor set.
enum SystemWallpaperStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static func snapshot() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Writes a snapshot back and restarts WallpaperAgent so it reloads it;
    /// launchd starts the agent again on demand.
    static func restore(_ data: Data) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Mosaic: could not restore wallpaper settings: \(error)")
            return
        }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAgent"]
        try? kill.run()
    }
}

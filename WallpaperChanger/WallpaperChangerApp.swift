import SwiftUI

@main
struct WallpaperChangerApp: App {
    @State private var store: WallpaperStore
    @State private var loginItem = LoginItem()
    private let engine: WallpaperEngine

    init() {
        let store = WallpaperStore()
        _store = State(initialValue: store)
        #if DEBUG
        let snapshotting = UserDefaults.standard.string(forKey: "snapshotMenu") != nil
        // Don't touch real wallpapers with fake displays.
        engine = WallpaperEngine(store: snapshotting ? WallpaperStore() : store)
        MenuSnapshot.runIfRequested(store: store)
        UpdateTestHook.runIfRequested()
        #else
        engine = WallpaperEngine(store: store)
        #endif
        UpdateService.shared.startAutomaticChecks()
    }

    var body: some Scene {
        MenuBarExtra("Wallpaper Changer", systemImage: "photo.on.rectangle.angled") {
            MenuContent()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Window("Wallpaper Changer Settings", id: "settings") {
            SettingsView()
                .environment(loginItem)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

import SwiftUI

@main
struct MosaicApp: App {
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
        MenuBarExtra("Mosaic", systemImage: "photo.on.rectangle.angled") {
            MenuContent()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Window("Mosaic Settings", id: "settings") {
            SettingsView()
                .environment(loginItem)
                .environment(store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

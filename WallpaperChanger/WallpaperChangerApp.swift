import SwiftUI

@main
struct WallpaperChangerApp: App {
    @State private var store: WallpaperStore
    @State private var loginItem = LoginItem()
    private let engine: WallpaperEngine

    init() {
        let store = WallpaperStore()
        _store = State(initialValue: store)
        engine = WallpaperEngine(store: store)
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

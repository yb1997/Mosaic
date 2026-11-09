import SwiftUI

@main
struct MosaicApp: App {
    @State private var store: WallpaperStore
    @State private var loginItem = LoginItem()
    private let engine: WallpaperEngine?

    /// Unit tests run inside the app. Then it uses a throwaway folder and
    /// starts nothing, so tests never touch real wallpapers, settings or images.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        if Self.isRunningTests {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("MosaicTestHost-\(UUID().uuidString)", isDirectory: true)
            _store = State(initialValue: WallpaperStore(directory: folder, defaults: UserDefaults(suiteName: "MosaicTestHost") ?? .standard))
            engine = nil
            return
        }
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
        DispatchQueue.main.async {
            StatusItemDropTarget.start(store: store)
            MenuPanelAnchor.start()
        }
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
        .windowResizability(.contentMinSize)
        .defaultSize(width: 715, height: 500)
        .defaultLaunchBehavior(.suppressed)
    }
}

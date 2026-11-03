#if DEBUG
import Foundation

/// `-testInstallUpdate` installs an update a few seconds after launch, from the DMG
/// in the MOSAIC_UPDATE_TEST_DMG environment variable (a file:// URL), or from the latest
/// release when it isn't set. Run it from a copy outside /Applications built with a
/// lower MARKETING_VERSION; never publish a throwaway release to test this.
enum UpdateTestHook {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-testInstallUpdate") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var dmg = ProcessInfo.processInfo.environment["MOSAIC_UPDATE_TEST_DMG"].flatMap(URL.init(string:))
            if dmg == nil {
                await UpdateService.shared.checkForUpdates()
                dmg = UpdateService.shared.dmgURL
            }
            guard let dmg else {
                print("[UpdateTestHook] no DMG to install")
                return
            }
            print("[UpdateTestHook] installing \(dmg)")
            await UpdateInstaller.shared.install(from: dmg)
            print("[UpdateTestHook] state: \(UpdateInstaller.shared.state)")
        }
    }
}
#endif

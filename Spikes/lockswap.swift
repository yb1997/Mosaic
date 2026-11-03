// Spike 2: the lock screen shows the desktop wallpaper, so swap the desktop
// to a "lock" image when the screen locks and put it back on unlock.
//
//   ./lockswap <image for screen 1> [<image for screen 2> ...]
//
// Screens are taken in NSScreen order. Uses only the public
// NSWorkspace.setDesktopImageURL API to swap; the spike restores by writing
// back the saved Index.plist (the real app would re-set its own image files).

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let storeURL = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
let images = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL }
guard !images.isEmpty else { print("usage: ./lockswap <image per screen>..."); exit(1) }
var saved: Data?

func log(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
    fflush(stdout)
}

func name(_ screen: NSScreen) -> String {
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    return "\(screen.localizedName) #\(id)"
}

func swapIn() {
    saved = try? Data(contentsOf: storeURL)
    for (i, screen) in NSScreen.screens.enumerated() {
        let image = images[min(i, images.count - 1)]
        do {
            try NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:])
            log("set \(image.lastPathComponent) on \(name(screen))")
        } catch {
            log("failed on \(name(screen)): \(error)")
        }
    }
}

func swapOut() {
    guard let saved else { return }
    try? saved.write(to: storeURL, options: .atomic)
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    kill.arguments = ["WallpaperAgent"]
    try? kill.run()
    kill.waitUntilExit()
    log("restored the saved wallpaper settings")
}

let center = DistributedNotificationCenter.default()
center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    log("screen locked")
    swapIn()
}
center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
    log("screen unlocked")
    swapOut()
}
signal(SIGTERM) { _ in exit(0) }
log("waiting for lock; screens: \(NSScreen.screens.map(name))")
RunLoop.main.run()

// Video wallpaper spike: a looping, muted video in a click-through window just
// above the desktop picture on every screen, on every Space.
//
//   swiftc -O videospike.swift -o videospike
//   ./videospike <video> [seconds=20]
//
// Quits by itself after `seconds`, so it never stays over the desktop.
// Logs occlusion changes, so you can see whether pausing under full-screen apps
// would work.
import AppKit
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: videospike <video> [seconds]")
    exit(1)
}
let videoURL = URL(fileURLWithPath: args[1])
let seconds = args.count >= 3 ? Double(args[2]) ?? 20 : 20

func log(_ message: String) {
    let time = Date().formatted(.dateTime.hour().minute().second())
    print("\(time) \(message)")
    fflush(stdout)
}

final class Wallpaper: NSObject, NSWindowDelegate {
    let window: NSWindow
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?
    let name: String

    init(screen: NSScreen, url: URL) {
        name = screen.localizedName
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        // Same level as Mosaic's fade overlay: above the picture, below icons and widgets.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Unlike the fade overlay, this one stays on every Space.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.delegate = self

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        window.contentView = view

        player.isMuted = true
        // Defaults to true on macOS: a looping wallpaper would keep the display awake.
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        window.orderFrontRegardless()
        player.play()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window.occlusionState.contains(.visible)
        log("\(name): \(visible ? "visible" : "occluded")")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let wallpapers = NSScreen.screens.map { Wallpaper(screen: $0, url: videoURL) }
log("pid \(getpid()), playing on \(wallpapers.map(\.name).joined(separator: ", ")) for \(Int(seconds)) s")

let workspace = NSWorkspace.shared.notificationCenter
workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
    log("Space changed")
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    log("screen parameters changed (windows are not re-laid out in this spike)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    log("done")
    exit(0)
}
app.run()

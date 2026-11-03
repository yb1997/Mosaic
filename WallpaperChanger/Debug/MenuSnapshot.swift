#if DEBUG
import SwiftUI

/// `-snapshotMenu <path.png>` renders the menu panel to a PNG and quits, so
/// layout can be checked without clicking the menu bar. Combine with
/// `-fakeDisplays N`.
enum MenuSnapshot {
    @MainActor static func runIfRequested(store: WallpaperStore) {
        guard let path = UserDefaults.standard.string(forKey: "snapshotMenu") else { return }
        DispatchQueue.main.async {
            let view = NSHostingView(rootView: MenuContent().environment(store))
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            // Give onGeometryChange a pass to measure the sections.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.setContentSize(view.fittingSize)
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot \(Int(view.bounds.width))x\(Int(view.bounds.height)) pt, \(store.displays.count) displays")
                exit(0)
            }
        }
    }
}
#endif

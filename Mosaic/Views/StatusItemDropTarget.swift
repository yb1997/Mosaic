import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dragging an image onto the menu bar icon shows a drop shelf under it: every
/// screen's tiles, to drop the image on one. The menu panel itself can't help:
/// it closes as soon as another app is clicked, so a drag can't start with it
/// open, and macOS 26 opens it from the system side, so the app can't open it
/// mid-drag either.
///
/// SwiftUI's MenuBarExtra doesn't expose its status item, so this finds the
/// icon's windows (one per menu bar, the others being "replicants") and lays a
/// view over each that only takes part in drags; clicks still reach the icon.
@MainActor
enum StatusItemDropTarget {
    private static var store: WallpaperStore?
    private static var shelf: NSPanel?
    private static var releaseTimer: Timer?
    private static var screenObserver: NSObjectProtocol?

    /// Call once at launch.
    static func start(store: WallpaperStore) {
        self.store = store
        install()
        // Icon windows are added and replaced when screens change.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { install(attempts: 4) }
            }
        }
    }

    /// The icon's windows appear shortly after launch, so look again until they're there.
    private static func install(attempts: Int = 20) {
        let windows = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBarWindow") }
        guard !windows.isEmpty else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { install(attempts: attempts - 1) }
            } else {
                Log.ui.error("Menu bar icon not found; dragging onto it won't show the drop shelf")
            }
            return
        }
        for window in windows {
            guard let content = window.contentView, !content.subviews.contains(where: { $0 is DropView }) else { continue }
            let view = DropView(frame: content.bounds)
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
    }

    // MARK: - Shelf

    fileprivate static func showShelf(below iconFrame: NSRect) {
        guard let store, !store.displays.isEmpty else { return }
        let panel = shelf ?? makeShelf(store: store)
        shelf = panel
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(iconFrame) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? iconFrame
        let x = min(max(iconFrame.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: iconFrame.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        watchForRelease()
    }

    private static func makeShelf(store: WallpaperStore) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = NSHostingView(rootView: DropShelf().environment(store))
        return panel
    }

    /// The shelf lasts as long as the drag: once the mouse button is up (the
    /// image was dropped, or the drag ended elsewhere), it goes away.
    private static func watchForRelease() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                releaseTimer?.invalidate()
                releaseTimer = nil
                // Let a drop on a tile finish first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { shelf?.orderOut(nil) }
            }
        }
    }

    // MARK: - Drop view

    private final class DropView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
                + [UTType.movie, .quickTimeMovie, .mpeg4Movie].map { NSPasteboard.PasteboardType($0.identifier) })
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Invisible to clicks, so the icon underneath still opens the panel.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard Self.carriesImage(sender), let window else { return [] }
            StatusItemDropTarget.showShelf(below: window.frame)
            // Nothing is dropped on the icon itself; the shelf's tiles take it.
            return []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

        private static func carriesImage(_ info: NSDraggingInfo) -> Bool {
            let pasteboard = info.draggingPasteboard
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                return urls.contains {
                    UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true || VideoFile.isVideoSource($0)
                }
            }
            return pasteboard.types?.contains {
                guard let type = UTType($0.rawValue) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .movie)
            } == true
        }
    }
}

/// Every screen's tiles, shown while an image is dragged onto the menu bar icon.
private struct DropShelf: View {
    @Environment(WallpaperStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Drop on a tile", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.displays.prefix(4)) { display in
                DisplaySection(display: display, showsLockToggle: false)
            }
        }
        .frame(width: 280)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(8)
        .fixedSize()
    }
}

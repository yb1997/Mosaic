import AppKit

/// Keeps the menu panel under the icon that was clicked.
///
/// macOS has one status item and moves it to the menu bar of the display in
/// use. For a moment during the move it reports a position about 250pt off, and
/// if that's when the icon was clicked, MenuBarExtra opens the panel there and
/// never corrects it. The click itself says where the icon really is.
@MainActor
enum MenuPanelAnchor {
    private static var observer: NSObjectProtocol?

    /// Call once at launch.
    static func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.keyWindow,
                      String(describing: type(of: window)).contains("MenuBarExtraWindow"),
                      let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
                else { return }
                let mouse = NSEvent.mouseLocation
                guard let x = correctedX(panelFrame: window.frame, mouse: mouse, screen: screen.frame, menuBarBottom: screen.visibleFrame.maxY) else { return }
                Log.ui.info("Moving menu panel from x=\(window.frame.minX) to x=\(x), under the click")
                window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
            }
        }
    }

    /// Where the panel should go instead, or nil if it's fine where it is.
    /// Only a click in this screen's menu bar says anything about the icon.
    nonisolated static func correctedX(panelFrame: NSRect, mouse: NSPoint, screen: NSRect, menuBarBottom: CGFloat) -> CGFloat? {
        // Not `screen.contains`: a click on the top row reports y == maxY, which it excludes.
        guard mouse.x >= screen.minX, mouse.x < screen.maxX, mouse.y >= menuBarBottom, mouse.y <= screen.maxY else { return nil }
        let iconHalfWidth: CGFloat = 19
        let tolerance: CGFloat = 60
        let wanted = min(mouse.x - iconHalfWidth, screen.maxX - panelFrame.width - 8)
        return abs(panelFrame.minX - wanted) > tolerance ? max(wanted, screen.minX + 8) : nil
    }
}

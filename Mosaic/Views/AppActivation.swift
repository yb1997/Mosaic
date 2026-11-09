import AppKit
import SwiftUI

/// Brings a window forward from a click in the menu panel. macOS refuses to
/// activate a menu bar app (LSUIElement) from there, so Mosaic becomes a
/// regular app, with a Dock icon, while one of these windows is open.
@MainActor
enum AppActivation {
    private(set) static weak var settingsWindow: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func begin() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Activating can be refused, or undone as the menu panel closing hands
    /// focus back to the previous app. Floating keeps the window in front
    /// meanwhile; once Mosaic has stayed active it's a normal window again,
    /// so switching to another app can cover it. `window` may be nil at first.
    static func keepInFront(_ window: () -> NSWindow?) async {
        var wasVisible = false
        for tick in 0..<16 {
            if tick > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let current = window() else { continue }
            if current.isVisible {
                wasVisible = true
            } else if wasVisible {
                current.level = .normal
                return
            } else {
                continue
            }
            current.level = .floating
            if !NSApp.isActive || !current.isKeyWindow {
                NSApp.activate()
                current.makeKeyAndOrderFront(nil)
            }
        }
        if NSApp.isActive { window()?.level = .normal }
    }

    /// Goes back to being a menu bar app, unless a picker or Settings is still open.
    /// `closing` is a picker that is on its way out.
    static func endIfIdle(closing: NSWindow? = nil) {
        let pickerOpen = NSApp.windows.contains { $0 is NSOpenPanel && $0 !== closing && $0.isVisible }
        if !pickerOpen, settingsWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    fileprivate static func track(_ window: NSWindow) {
        guard window !== settingsWindow else { return }
        settingsWindow = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // After the close, so the window no longer counts as open.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { endIfIdle() }
            }
        }
    }
}

/// Tells `AppActivation` which window is Settings.
struct SettingsWindowTracker: NSViewRepresentable {
    private final class Tracker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { AppActivation.track(window) }
        }
    }

    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}
}

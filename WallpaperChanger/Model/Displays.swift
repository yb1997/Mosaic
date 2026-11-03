import AppKit

/// A connected screen, identified by its CoreGraphics display UUID, which
/// survives reconnects and reordering (NSScreen order and display IDs do not).
struct Display: Identifiable, Hashable {
    let id: String
    let name: String
    let isMain: Bool
    let screen: NSScreen

    @MainActor static var connected: [Display] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = screen.displayUUID else { return nil }
            return Display(id: uuid, name: screen.localizedName, isMain: CGDisplayIsMain(screen.displayID) != 0, screen: screen)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    var displayUUID: String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

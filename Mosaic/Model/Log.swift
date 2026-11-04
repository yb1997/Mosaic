import os

/// Unified logging. Read with Console.app or:
/// `log stream --predicate 'subsystem == "in.ybear.Mosaic"'`
enum Log {
    private static let subsystem = "in.ybear.Mosaic"
    /// Setting wallpapers on screens.
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Swapping the desktop at lock time and putting macOS's settings back.
    static let lockSwap = Logger(subsystem: subsystem, category: "lockSwap")
    /// Copying picked and dropped images in.
    static let imports = Logger(subsystem: subsystem, category: "imports")
    /// Saving state.json and profiles.json.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Checking for and installing updates.
    static let updater = Logger(subsystem: subsystem, category: "updater")
    /// Menu bar icon and drop shelf.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

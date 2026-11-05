import AppKit

/// How an image is fitted to its screen, the same choices macOS offers.
enum Scaling: String, Codable, CaseIterable {
    /// Covers the screen, cropping what doesn't fit. The default.
    case fill
    /// Shows the whole image, with bars around it.
    case fit
    /// Covers the screen, distorting the image.
    case stretch
    /// The image at its actual size, in the middle of the screen.
    case center

    var title: String {
        switch self {
        case .fill: "Fill Screen"
        case .fit: "Fit to Screen"
        case .stretch: "Stretch to Fill"
        case .center: "Center"
        }
    }

    private var imageScaling: NSImageScaling {
        switch self {
        case .fill, .fit: .scaleProportionallyUpOrDown
        case .stretch: .scaleAxesIndependently
        case .center: .scaleNone
        }
    }

    private var allowsClipping: Bool { self == .fill || self == .stretch }

    /// How much Center shrinks an image: one image pixel per screen pixel,
    /// except that an image bigger than the screen both ways is scaled down
    /// until it just covers it (as Fill would). Measured on macOS 27.2.
    static func centerScale(image: CGSize, screen: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return min(1, max(screen.width / image.width, screen.height / image.height))
    }

    /// Bars around Fit and Center images.
    static let fillColor = NSColor.black

    var options: [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: imageScaling.rawValue,
            .allowClipping: allowsClipping,
        ]
        if self == .fit || self == .center { options[.fillColor] = Self.fillColor }
        return options
    }

    /// Whether options read back from NSWorkspace already show this scaling.
    /// macOS leaves out the clipping key for Stretch and Center, and always
    /// returns some fill colour (left over from an earlier call), so only
    /// the scaling and, when present, the clipping are compared.
    func matches(_ current: [NSWorkspace.DesktopImageOptionKey: Any]?) -> Bool {
        guard let current,
              let raw = (current[.imageScaling] as? NSNumber)?.uintValue,
              raw == imageScaling.rawValue
        else { return false }
        guard let clipping = current[.allowClipping] as? Bool else { return true }
        return clipping == allowsClipping
    }
}

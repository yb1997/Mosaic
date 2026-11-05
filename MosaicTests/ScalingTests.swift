import AppKit
import Testing
@testable import Mosaic

/// The options each mode sends, and how options read back from macOS are
/// matched (checked by hand on macOS 27.2: no clipping key for Stretch and
/// Center, and always a fill colour).
struct ScalingTests {
    typealias Options = [NSWorkspace.DesktopImageOptionKey: Any]

    @Test func everyModeMatchesItsOwnOptions() {
        for scaling in Scaling.allCases {
            #expect(scaling.matches(scaling.options), "\(scaling)")
            for other in Scaling.allCases where other != scaling {
                #expect(!scaling.matches(other.options), "\(scaling) vs \(other)")
            }
        }
    }

    @Test func matchesWhatMacOSReadsBack() {
        let blue = NSColor.blue
        let fill: Options = [.imageScaling: NSNumber(value: 3), .allowClipping: true, .fillColor: blue]
        let fit: Options = [.imageScaling: NSNumber(value: 3), .allowClipping: false, .fillColor: blue]
        let stretch: Options = [.imageScaling: NSNumber(value: 1), .fillColor: blue]
        let center: Options = [.imageScaling: NSNumber(value: 2), .fillColor: blue]
        #expect(Scaling.fill.matches(fill) && !Scaling.fill.matches(fit))
        #expect(Scaling.fit.matches(fit) && !Scaling.fit.matches(fill))
        #expect(Scaling.stretch.matches(stretch) && !Scaling.stretch.matches(center))
        #expect(Scaling.center.matches(center) && !Scaling.center.matches(stretch))
    }

    @Test func noOptionsNeverMatch() {
        #expect(!Scaling.fill.matches(nil))
        #expect(!Scaling.fill.matches([:]))
    }

    /// Center as measured on a 3024 × 1964 screen: actual size unless the
    /// image is bigger both ways, then shrunk just enough to cover.
    @Test func centerShrinksOnlyImagesBiggerBothWays() {
        let screen = CGSize(width: 3024, height: 1964)
        #expect(Scaling.centerScale(image: CGSize(width: 1280, height: 720), screen: screen) == 1)
        #expect(Scaling.centerScale(image: CGSize(width: 3600, height: 1000), screen: screen) == 1)
        #expect(Scaling.centerScale(image: CGSize(width: 1500, height: 2600), screen: screen) == 1)
        #expect(Scaling.centerScale(image: CGSize(width: 4032, height: 3024), screen: screen) == 0.75)
        #expect(Scaling.centerScale(image: .zero, screen: screen) == 1)
    }
}

import XCTest
@testable import Mosaic

final class MenuPanelAnchorTests: XCTestCase {
    private let screen = NSRect(x: 1512, y: 144, width: 2304, height: 1296)
    private let menuBarBottom: CGFloat = 1375
    private let mouse = NSPoint(x: 2933, y: 1390)

    private func panel(x: CGFloat) -> NSRect { NSRect(x: x, y: 985, width: 308, height: 420) }

    private func corrected(_ frame: NSRect, mouse: NSPoint) -> CGFloat? {
        MenuPanelAnchor.correctedX(panelFrame: frame, mouse: mouse, screen: screen, menuBarBottom: menuBarBottom)
    }

    func testLeavesCorrectlyPlacedPanelAlone() {
        XCTAssertNil(corrected(panel(x: 2915), mouse: mouse))
    }

    func testMovesPanelOpenedRightOfTheIcon() {
        XCTAssertEqual(corrected(panel(x: 3166), mouse: mouse), 2914)
    }

    func testMovesPanelOpenedLeftOfTheIcon() {
        XCTAssertEqual(corrected(panel(x: 2660), mouse: mouse), 2914)
    }

    func testCountsAClickOnTheTopRowOfTheScreen() {
        XCTAssertEqual(corrected(panel(x: 3166), mouse: NSPoint(x: 2933, y: screen.maxY)), 2914)
    }

    func testIgnoresMouseOutsideTheMenuBar() {
        XCTAssertNil(corrected(panel(x: 3166), mouse: NSPoint(x: 2933, y: 900)))
    }

    func testLeavesPanelClampedAtTheScreenEdgeAlone() {
        let edgeX = screen.maxX - 308 - 8
        XCTAssertNil(corrected(panel(x: edgeX), mouse: NSPoint(x: screen.maxX - 30, y: 1390)))
    }
}

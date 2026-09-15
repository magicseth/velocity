import XCTest
@testable import TerminalVelocity

final class MenuBarFallbackTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: 0, y: 950, width: 650, height: 32)
    let right = CGRect(x: 862, y: 950, width: 650, height: 32)
    func accessible(_ rect: CGRect?, visible: Bool = true) -> Bool {
        MenuBarVisibility.accessible(button: rect, screen: screen, menuHeight: 32, left: left, right: right, visible: visible)
    }
    func testNotchAndHiddenOrOffscreenIconTriggerFallback() {
        XCTAssertTrue(accessible(CGRect(x: 1000, y: 955, width: 24, height: 24)))
        XCTAssertFalse(accessible(CGRect(x: 750, y: 955, width: 24, height: 24)))
        XCTAssertFalse(accessible(CGRect(x: 850, y: 955, width: 24, height: 24)))
        XCTAssertFalse(accessible(CGRect(x: 0, y: -6, width: 24, height: 24)))
        XCTAssertFalse(accessible(CGRect(x: 1000, y: 955, width: 24, height: 24), visible: false))
        XCTAssertFalse(accessible(nil))
    }
    func testFallbackRemainsInsideUsableAreaOnOffsetDisplay() {
        let screen = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let visible = CGRect(x: -1512, y: 250, width: 1512, height: 900)
        let frame = MenuBarVisibility.fallbackFrame(screen: screen, visible: visible, safeTop: 32)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertLessThan(frame.maxY, screen.maxY - 32)
    }
    func testDebounceAvoidsFlickerDuringMenuBarRepositioning() {
        var state = MenuBarVisibility()
        XCTAssertFalse(state.observe(accessible: false))
        XCTAssertTrue(state.observe(accessible: false))
        XCTAssertTrue(state.observe(accessible: true))
        XCTAssertTrue(state.observe(accessible: true))
        XCTAssertFalse(state.observe(accessible: true))
    }
}

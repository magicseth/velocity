import XCTest
import AppKit
@testable import TerminalVelocity

final class CloseResultTests: XCTestCase {
    func testChromeClosesOnlyTheStableTabID() {
        let tab = BrowserTab(browserID: "com.google.Chrome", windowID: 3, tabID: 42,
                             title: "Example", url: "https://example.com", minimized: false, windowTitle: "Example", index: 1)
        let source = BrowserTabs.closingSource(tab)
        XCTAssertTrue(source.contains("id of tab n of w as integer) is 42"))
        XCTAssertTrue(source.contains("close tab n of w"))
        XCTAssertFalse(source.contains("close window"))
        XCTAssertFalse(source.contains("set active tab index"))
        XCTAssertFalse(source.contains("set index of w"))
    }

    func testSafariRetainsIdentityChecksBeforeClosing() {
        let tab = BrowserTab(browserID: "com.apple.Safari", windowID: 9, tabID: 2,
                             title: "Example \"quote\"", url: "https://example.com", minimized: true, windowTitle: "Example", index: 2)
        let source = BrowserTabs.closingSource(tab)
        XCTAssertTrue(source.contains("set w to window id 9"))
        XCTAssertTrue(source.contains("URL of t is wantedURL and name of t is wantedTitle"))
        XCTAssertTrue(source.contains("if (count of hits) is not 1 then return false"))
        XCTAssertTrue(source.contains("close tab chosen of w"))
        XCTAssertFalse(source.contains("set current tab"))
        XCTAssertFalse(source.contains("close window"))
        XCTAssertTrue(source.contains("Example \\\"quote\\\""))
    }

    func testLaunchableAppsCannotBeQuit() {
        var entry = WindowEntry(id: "app", pid: 0, appName: "Example", title: "Example", icon: nil,
                                element: nil, minimized: false, hidden: false, terminal: false)
        XCTAssertTrue(entry.canClose)
        XCTAssertEqual(entry.closeLabel, "Quit app")
        entry.launchURL = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertFalse(entry.canClose)
    }
}

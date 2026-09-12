import XCTest
import AppKit
@testable import TerminalVelocity

final class BrowserSelectionTests: XCTestCase {
    func testChromeSelectionUsesBulkIDsAndPrioritizesOriginalWindow() {
        let tab = BrowserTab(browserID: "com.google.Chrome", windowID: 123, tabID: 456,
                             title: "Inbox", url: "https://mail.google.com/mail/u/0/#inbox", minimized: false,
                             windowTitle: "Inbox", index: 2)
        let source = BrowserTabs.selectionSource(tab)
        XCTAssertTrue(source.contains("set end of candidates to window id 123"))
        XCTAssertTrue(source.contains("id of every tab of w"))
        XCTAssertTrue(source.contains("return (id of active tab of w as integer) is 456"))
        XCTAssertFalse(source.contains("id of tab n of w"))
        XCTAssertFalse(source.contains("URL of")) // tab survives Gmail route/title changes
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: tab.browserID) != nil {
            var error: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&error), "\(String(describing: error))")
        }
    }
}

import XCTest
import AppKit
@testable import TerminalVelocity

final class BrowserSelectionTests: XCTestCase {
    @MainActor func testSlowSelectionLeavesMainActorResponsive() async {
        var heartbeat = false
        let tick = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            heartbeat = true
        }
        let started = Date()
        let selection = Task { await BrowserTabs.runSelectionScript("delay 2\nreturn true") }
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(heartbeat, "Main actor must keep processing while browser scripting waits")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        let result = await selection.value
        XCTAssertTrue(result)
        await tick.value
    }

    func testSelectionFailsClosedOnScriptErrorsAndFalseResults() async {
        let negative = await BrowserTabs.runSelectionScript("return false")
        let failure = await BrowserTabs.runSelectionScript("error \"test failure\"")
        XCTAssertFalse(negative)
        XCTAssertFalse(failure)
    }

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

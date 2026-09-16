import XCTest
import AppKit
@testable import TerminalVelocity

final class ClosedTabTests: XCTestCase {
    func entry(_ id: Int = 1, eligible: Bool = true, url: String = "https://example.com/page") -> WindowEntry {
        WindowEntry(id: "tab-\(id)", pid: 123, appName: "Google Chrome", title: "Example", icon: nil,
            element: nil, minimized: false, hidden: false, terminal: false,
            browserTab: BrowserTab(browserID: "com.google.Chrome", windowID: 5, tabID: id,
                title: "Example", url: url, minimized: false, windowTitle: "Example", index: 1,
                historyEligible: eligible), browser: true, browserProfile: "Work")
    }
    @MainActor func testConfirmedClosureAndGapProtection() {
        let history = ClosedTabs(file: nil), launch = Date()
        history.observe([entry()], complete: true, launch: launch)
        history.observe([], complete: true, launch: launch)
        XCTAssertTrue(history.records.isEmpty)
        history.observe([entry()], complete: true, launch: launch)
        XCTAssertTrue(history.records.isEmpty)
        history.observe([], complete: false, launch: launch)
        history.observe([], complete: true, launch: launch)
        XCTAssertTrue(history.records.isEmpty)
        history.observe([entry()], complete: true, launch: launch)
        history.observe([], complete: true, launch: launch)
        history.observe([], complete: true, launch: launch)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.profile, "Work")
        XCTAssertTrue(SearchQuery("@closed example").accepts(history.records[0].entry, recent: false))
        XCTAssertFalse(SearchQuery("@closed").accepts(entry(), recent: false))
        XCTAssertFalse(history.records[0].entry.canClose)
        history.remove(history.records[0].id)
        XCTAssertTrue(history.records.isEmpty)
    }
    @MainActor func testPrivateTabsNavigationAndProcessReplacementAreNotClosures() {
        let history = ClosedTabs(file: nil), launch = Date()
        history.observe([entry(1, eligible: false), entry(2)], complete: true, launch: launch)
        history.observe([entry(2, url: "https://example.com/new")], complete: true, launch: launch)
        history.observe([entry(2, url: "https://example.com/new")], complete: true, launch: launch)
        XCTAssertTrue(history.records.isEmpty)
        history.observe([], complete: true, launch: launch.addingTimeInterval(1))
        history.observe([], complete: true, launch: launch.addingTimeInterval(1))
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(ClosedTabs.validURL("https://user:secret@example.com"))
        XCTAssertFalse(ClosedTabs.validURL("javascript:alert(1)"))
    }
    @MainActor func testPersistenceExpiryAndScriptsCompile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json"), launch = Date()
        let history = ClosedTabs(file: file)
        history.observe([entry()], complete: true, launch: launch)
        history.observe([], complete: true, launch: launch)
        history.observe([], complete: true, launch: launch)
        XCTAssertEqual(ClosedTabs(file: file).records.count, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        for source in [history.records[0].reopenSource, BrowserTabs.scanSource(browserID: "com.google.Chrome"), BrowserTabs.scanSource(browserID: "com.apple.Safari")] {
            var error: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&error), "\(String(describing: error))")
        }
        history.observe([], complete: true, launch: launch, now: Date().addingTimeInterval(8 * 86400))
        XCTAssertTrue(history.records.isEmpty)
    }
}

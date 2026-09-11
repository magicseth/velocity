import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class BrowserProfileTests: XCTestCase {
    func testExtractsProfileAndIncognitoFromWindowSuffix() {
        XCTAssertEqual(WindowCatalog.profileName(windowTitle: "Inbox - Google Chrome - Seth (work.example)", appName: "Google Chrome"), "Seth (work.example)")
        XCTAssertEqual(WindowCatalog.profileName(windowTitle: "Inbox - Google Chrome (Incognito)", appName: "Google Chrome"), "Incognito")
        XCTAssertNil(WindowCatalog.profileName(windowTitle: "Inbox", appName: "Google Chrome"))
    }
    func testDuplicateInboxWindowsUseUniqueSiblingTabEvidence() {
        let a = AXUIElementCreateApplication(1101), b = AXUIElementCreateApplication(1102)
        func ax(_ id: String, _ title: String, _ element: AXUIElement, tab: Bool = false) -> WindowEntry {
            WindowEntry(id: id, pid: 100, appName: "Google Chrome", title: title, icon: nil,
                        element: element, minimized: false, hidden: false, terminal: false,
                        tab: tab ? AXUIElementCreateApplication(1103) : nil, browser: true)
        }
        func script(_ window: Int, _ title: String, _ index: Int) -> BrowserTab {
            BrowserTab(browserID: "com.google.Chrome", windowID: window, tabID: window * 10 + index,
                title: title, url: "https://example.com", minimized: false, windowTitle: "Inbox", index: index)
        }
        let windows = [ax("work", "Inbox - Google Chrome - Work", a), ax("home", "Inbox - Google Chrome - Home", b)]
        let tabs = [ax("one", "Work project", a, tab: true), ax("two", "Home project", b, tab: true)]
        let scripts = [script(1, "Inbox", 1), script(1, "Work project", 2), script(2, "Inbox", 1), script(2, "Home project", 2)]
        let matches = WindowCatalog.browserWindowAssociations(windows: windows, accessibleTabs: tabs, scriptTabs: scripts, appName: "Google Chrome")
        XCTAssertEqual(matches[1]?.id, "work")
        XCTAssertEqual(matches[2]?.id, "home")
        XCTAssertTrue(WindowCatalog.browserWindowAssociations(windows: windows, accessibleTabs: [], scriptTabs: scripts, appName: "Google Chrome").isEmpty)
    }
    func testProfileIsVisibleAndSearchable() {
        let entry = WindowEntry(id: "tab", pid: 1, appName: "Google Chrome", title: "Inbox", icon: nil,
            element: nil, minimized: false, hidden: false, terminal: false, browser: true, browserProfile: "Work")
        XCTAssertTrue(entry.subtitle.contains("Work"))
        XCTAssertTrue(entry.searchText.contains("Work"))
    }
}

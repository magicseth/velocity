import XCTest
import AppKit
@testable import TerminalVelocity

final class TabCleanupTests: XCTestCase {
    func tab(_ id: Int = 1, url: String = "https://example.com/a?x=1#top", window: Int = 4, active: Bool = false) -> BrowserTab {
        BrowserTab(browserID: "com.google.Chrome", windowID: window, tabID: id, title: "Example", url: url,
                   minimized: false, windowTitle: "Example", index: id, isActive: active, loading: false)
    }
    func entry(_ tab: BrowserTab) -> WindowEntry {
        WindowEntry(id: "\(tab.windowID):\(tab.tabID)", pid: 1, appName: "Chrome", title: tab.title,
                    icon: nil, element: nil, minimized: false, hidden: false, terminal: false, browserTab: tab)
    }
    func testExactDuplicatesKeepProtectedCopyAndNeverCrossWindowsOrNormalizeURL() {
        let entries = [entry(tab(1)), entry(tab(2, active: true)), entry(tab(3)),
                       entry(tab(4, url: "https://example.com/a?x=2#top")),
                       entry(tab(5, url: "https://example.com/a?x=1#other")), entry(tab(6, window: 5))]
        let ids = TabCleanup.duplicateIDs(entries, isEligible: { !$0.browserTab!.isActive })
        XCTAssertEqual(ids, ["4:1", "4:3"])
        XCTAssertEqual(TabCleanup.duplicateIDs([entry(tab(1)), entry(tab(2))], isEligible: { _ in true }), ["4:2"])
    }
    func testProtectionAndUnsupportedURLs() {
        func eligible(_ t: BrowserTab, audio: AudioBadge = .none, ax: Bool = true, pinned: Bool = false) -> Bool {
            TabCleanup.metadataEligible(t, audio: audio, hasAX: ax, pinned: pinned)
        }
        XCTAssertTrue(eligible(tab()))
        XCTAssertFalse(eligible(tab(active: true)))
        var loading = tab(); loading.loading = true
        XCTAssertFalse(eligible(loading))
        for audio in [AudioBadge.playing, .muted, .appOutput] { XCTAssertFalse(eligible(tab(), audio: audio)) }
        XCTAssertFalse(eligible(tab(), ax: false))
        XCTAssertFalse(eligible(tab(), pinned: true))
        for url in ["chrome://settings", "file:///tmp/a", "https://user:pass@example.com", "not a URL"] {
            XCTAssertFalse(eligible(tab(url: url)))
        }
    }
    func testActivityStartsNowPersistsAndResetsOnObservedUseOrNavigation() {
        let name = "CleanupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let activity = TabActivity(defaults: defaults)
        let t = tab()
        activity.observe([t], now: 100)
        XCTAssertFalse(activity.old(t, days: 7, now: 100))
        let later = 100.0 + 8 * 86400
        activity.observe([t], now: later)
        XCTAssertTrue(activity.old(t, days: 7, now: later))
        XCTAssertTrue(TabActivity(defaults: defaults).old(t, days: 7, now: later))
        XCTAssertFalse(activity.old(tab(url: "https://example.com/new"), days: 7, now: later))
        activity.observe([tab(active: true)], now: later)
        XCTAssertFalse(activity.old(t, days: 7, now: later))
        XCTAssertFalse(activity.old(t, days: 7, now: later + 9 * 86400)) // no fresh scan
        XCTAssertFalse(String(data: defaults.data(forKey: "tabCleanupActivity")!, encoding: .utf8)!.contains("example.com"))
    }
    func testCleanupScriptsCompileAndGuardIdentityActiveAndLastCopy() {
        for browser in ["com.google.Chrome", "com.apple.Safari"] {
            let t = BrowserTab(browserID: browser, windowID: 5, tabID: 2, title: "a \"quoted\" title", url: "https://example.com/?q=\"hi\"",
                               minimized: false, windowTitle: "", index: 2)
            let source = TabCleanup.closeSource(t, duplicate: true)
            XCTAssertTrue(source.contains("if copies < 2 then return false"))
            XCTAssertTrue(source.contains("URL of t is wantedURL"))
            XCTAssertTrue(source.contains("is wantedTitle"))
            XCTAssertTrue(source.contains("if chosen is ("))
            XCTAssertFalse(source.contains("activate"))
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) != nil else { continue }
            var error: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&error), "\(String(describing: error))")
            XCTAssertTrue(NSAppleScript(source: BrowserTabs.scanSource(browserID: browser))!.compileAndReturnError(&error), "\(String(describing: error))")
        }
    }
}

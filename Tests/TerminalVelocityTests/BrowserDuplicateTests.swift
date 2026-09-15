import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class BrowserDuplicateTests: XCTestCase {
    func testWindowIsReplacedByItsTabKeepingAudioAndOtherTabs() {
        let window = AXUIElementCreateApplication(1001)
        func entry(_ id: String, title: String, tab: Bool, element: AXUIElement) -> WindowEntry {
            WindowEntry(id: id, pid: 1001, appName: "Google Chrome", title: title, icon: nil,
                element: element, minimized: false, hidden: false, terminal: false,
                tab: tab ? AXUIElementCreateApplication(1002) : nil, audio: tab ? .playing : .none, browser: true)
        }
        let parent = entry("window", title: "Video - Audio playing - Google Chrome - Profile", tab: false, element: window)
        let tab = entry("tab", title: "Video", tab: true, element: window)
        let otherTab = entry("other-tab", title: "Different page", tab: true, element: window)
        let otherWindow = entry("other-window", title: "Video - Google Chrome", tab: false, element: AXUIElementCreateApplication(1003))
        let result = ResultDeduplication.removingBrowserWindowDuplicates([parent, tab, otherTab, otherWindow])
        XCTAssertEqual(result.map(\.id), ["tab", "other-tab", "other-window"])
        XCTAssertEqual(result.first?.audio, .playing)
        XCTAssertEqual(ResultDeduplication.removingBrowserWindowDuplicates([parent]).map(\.id), ["window"], "Explicit window searches and unavailable tabs must retain the window")
    }
    func testAudioWindowAndTabDeduplicateEvenWhenPlayerTitleDiffers() {
        let element = AXUIElementCreateApplication(1100)
        let window = WindowEntry(id: "window", pid: 1100, appName: "Chrome", title: "Song name", icon: nil,
                                 element: element, minimized: false, hidden: false, terminal: false, audio: .playing, browser: true)
        let tab = WindowEntry(id: "tab", pid: 1100, appName: "Chrome", title: "YouTube Music", icon: nil,
                              element: element, minimized: false, hidden: false, terminal: false,
                              tab: AXUIElementCreateApplication(1101), audio: .playing, browser: true)
        XCTAssertEqual(ResultDeduplication.removingBrowserWindowDuplicates([window, tab]).map(\.id), ["tab"])
        var different = tab
        different = WindowEntry(id: "other", pid: 1102, appName: "Chrome", title: "YouTube Music", icon: nil,
                                element: AXUIElementCreateApplication(1102), minimized: false, hidden: false, terminal: false,
                                tab: AXUIElementCreateApplication(1103), audio: .playing, browser: true)
        XCTAssertEqual(ResultDeduplication.removingBrowserWindowDuplicates([window, different]).count, 2)
    }

    func testNormalizationUsesTheActualAppNameAndPreservesDifferentTitles() {
        XCTAssertEqual(WindowCatalog.browserWindowTitle("Page - Audio playing - Browser X - Work", appName: "Browser X"), "Page")
        XCTAssertEqual(WindowCatalog.browserWindowTitle("Page about Browser X", appName: "Browser X"), "Page about Browser X")
        XCTAssertEqual(WindowCatalog.browserWindowTitle("Page", appName: "Safari"), "Page")
    }
    func testWindowAudioAnnotatesOnlyTheMatchingTabAndHonorsMute() {
        let element = AXUIElementCreateApplication(1010)
        func entry(_ id: String, _ title: String, tab: Bool, audio: AudioBadge = .none) -> WindowEntry {
            WindowEntry(id: id, pid: 1010, appName: "Google Chrome", title: title, icon: nil,
                element: element, minimized: false, hidden: false, terminal: false,
                tab: tab ? AXUIElementCreateApplication(1011) : nil, audio: audio, browser: true)
        }
        let window = entry("window", "Video - Audio playing - Google Chrome - Profile", tab: false)
        let tab = entry("tab", "Video", tab: true)
        let other = entry("other", "Other page", tab: true)
        XCTAssertEqual(WindowCatalog.applyingBrowserAudio([window, tab, other]).map(\.audio), [.playing, .playing, .none])
        let muted = entry("tab", "Video", tab: true, audio: .muted)
        XCTAssertEqual(WindowCatalog.applyingBrowserAudio([window, muted]).last?.audio, .muted)
        let duplicate = entry("duplicate", "Video", tab: true)
        XCTAssertEqual(WindowCatalog.applyingBrowserAudio([window, tab, duplicate]).map(\.audio), [.playing, .none, .none])
        let silent = entry("window", "Video - Google Chrome - Profile", tab: false)
        XCTAssertEqual(WindowCatalog.applyingBrowserAudio([silent, tab]).map(\.audio), [.none, .none])
    }

}

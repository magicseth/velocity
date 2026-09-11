import XCTest
import AppKit
@testable import TerminalVelocity

final class AudioTests: XCTestCase {
    func testChromeAudioAnnotations() {
        XCTAssertEqual(AudioBadge.fromTabMetadata(["Music - Audio playing"]), .playing)
        XCTAssertEqual(AudioBadge.fromTabMetadata(["Music - Audio muted"]), .muted)
        XCTAssertEqual(AudioBadge.fromTabMetadata(["This tab is playing audio."]), .playing)
        XCTAssertEqual(WindowCatalog.cleanTabTitle("Music - Audio playing"), "Music")
    }
    func testSafariMuteControlsAndNoTitleKeywordGuessing() {
        XCTAssertEqual(AudioBadge.fromTabMetadata(["Mute Tab"]), .playing)
        XCTAssertEqual(AudioBadge.fromTabMetadata(["Unmute Tab"]), .muted)
        XCTAssertEqual(AudioBadge.fromTabMetadata(["How to mute tab audio - YouTube"]), .none)
        XCTAssertEqual(AudioBadge.fromTabMetadata(["Camera or microphone recording"]), .none)
    }
    func testMutedTakesPriorityOverStalePlayingLabel() {
        XCTAssertEqual(AudioBadge.fromTabMetadata(["Music - Audio playing", "Unmute Tab"]), .muted)
    }
    func testScriptQuoteEscapesData() {
        XCTAssertEqual(BrowserTabs.quote("a\" & dangerous \\ text"), "\"a\\\" & dangerous \\\\ text\"")
    }

    func testBrowserScriptsCompileWithoutExecuting() {
        for browser in BrowserTabs.supported {
            let tab = BrowserTab(browserID: browser, windowID: 123, tabID: 2,
                title: "Title with \"quotes\" and \\slashes\nnew line", url: "https://example.com/?a=1&b=2",
                minimized: false, windowTitle: "Example", index: 2)
            for source in [BrowserTabs.scanSource(browserID: browser), BrowserTabs.selectionSource(tab)] {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)!
                XCTAssertTrue(script.compileAndReturnError(&error), "\(browser): \(String(describing: error))")
            }
        }
    }
}

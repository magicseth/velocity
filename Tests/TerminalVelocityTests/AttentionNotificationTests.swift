import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class AttentionNotificationTests: XCTestCase {
    func testRequestsNotifyOnceAndRearmAfterTheyResolve() {
        var tracker = AttentionTransitions()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(tracker.update(["one"], now: start), ["one"])
        XCTAssertTrue(tracker.update(["one"], now: start.addingTimeInterval(2)).isEmpty)
        XCTAssertTrue(tracker.update([], now: start.addingTimeInterval(4)).isEmpty)
        XCTAssertTrue(tracker.update(["one"], now: start.addingTimeInterval(6)).isEmpty, "Brief AX gaps must not alert again")
        XCTAssertEqual(tracker.update(["one", "two"], now: start.addingTimeInterval(8)), ["two"])
        _ = tracker.update([], now: start.addingTimeInterval(20))
        XCTAssertEqual(tracker.update(["one"], now: start.addingTimeInterval(22)), ["one"])
    }
    @MainActor func testWindowAndTabAreOneNotificationButSeparateQuestionsRemain() {
        let window = AXUIElementCreateApplication(801)
        func entry(_ id: String, title: String, tab: Bool) -> WindowEntry {
            WindowEntry(id: id, pid: 801, appName: "Terminal", title: title, icon: nil,
                element: window, minimized: false, hidden: false, terminal: true,
                tab: tab ? AXUIElementCreateApplication(802) : nil)
        }
        let entries = [
            entry("window", title: "project — [ . ] Action Required | Question — codex ◂ node — 120×40", tab: false),
            entry("tab", title: "~/project — [ ! ] Action Required | Question — codex ◂ node", tab: true),
            entry("another", title: "[ ! ] Action Required | Different question — codex", tab: true),
            entry("idle", title: "✳ Idle — claude", tab: true)
        ]
        let waiting = AttentionNotifications.waiting(entries)
        XCTAssertEqual(Set(waiting.values.map(\.id)), ["tab", "another"])
    }
}

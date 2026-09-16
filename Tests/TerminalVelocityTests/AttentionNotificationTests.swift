import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class AttentionNotificationTests: XCTestCase {
    func testNotificationDestinationSurvivesRestartButRejectsProcessReplacement() throws {
        let entry = WindowEntry(id: "tab-one", pid: 801, appName: "Terminal",
            title: "[ ! ] Action Required | Question — codex", icon: nil,
            element: AXUIElementCreateApplication(801), minimized: false, hidden: false, terminal: true,
            tab: AXUIElementCreateApplication(802))
        let launch = Date(timeIntervalSince1970: 100)
        let destination = try XCTUnwrap(AttentionDestination(entry: entry, launch: launch))
        let restored = try JSONDecoder().decode(AttentionDestination.self, from: JSONEncoder().encode(destination))
        XCTAssertEqual(restored.resolve([entry], launch: launch)?.id, entry.id)
        XCTAssertNil(restored.resolve([entry], launch: launch.addingTimeInterval(1)))
        XCTAssertNil(restored.resolve([], launch: launch))
        let otherWindow = WindowEntry(id: entry.id, pid: entry.pid, appName: entry.appName,
            title: entry.title, icon: nil, element: AXUIElementCreateApplication(803),
            minimized: false, hidden: false, terminal: true)
        XCTAssertNil(restored.resolve([otherWindow], launch: launch))
        var changed = entry; changed.title = "[ ! ] Action Required | Other task — codex"
        XCTAssertNil(restored.resolve([changed], launch: launch))
    }
    func testProjectTaskAndObservedExcerpt() {
        let entry = WindowEntry(id: "one", pid: 801, appName: "Terminal",
            title: "~/Projects/convexos — [ ! ] Action Required | Integrate HIVE-style dependency | convexos — codex",
            icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        let presentation = AttentionPresentation(entry)
        XCTAssertEqual(presentation.project, "convexos")
        XCTAssertEqual(presentation.task, "Integrate HIVE-style dependency")
        XCTAssertNil(AttentionPresentation.excerpt("This tab is in the background. Open it to read its current prompt."))
        XCTAssertNil(AttentionPresentation.excerpt("\n  \n"))
        XCTAssertEqual(AttentionPresentation.excerpt("Old output\n\nAllow this command?\n1. Yes\n2. No"), "Old output\nAllow this command?\n1. Yes\n2. No")
        XCTAssertLessThanOrEqual(AttentionPresentation.excerpt(String(repeating: "x", count: 1000))!.count, 500)
    }
    @MainActor func testNotificationTargetDoesNotFollowSelectionOrReusedTitle() {
        let original = WindowEntry(id: "tab-one", pid: 801, appName: "Terminal",
            title: "[ ! ] Action Required | Question — codex", icon: nil,
            element: AXUIElementCreateApplication(801), minimized: false, hidden: false, terminal: true)
        let other = WindowEntry(id: "tab-two", pid: 801, appName: "Terminal",
            title: original.title, icon: nil, element: original.element,
            minimized: false, hidden: false, terminal: true)
        XCTAssertEqual(AttentionNotifications.target(original, in: [other, original])?.id, original.id)
        XCTAssertNil(AttentionNotifications.target(original, in: [other]))
        var changed = original
        changed.title = "[ ! ] Action Required | Different task — codex"
        XCTAssertNil(AttentionNotifications.target(original, in: [changed]))
        XCTAssertNil(AttentionNotifications.target(original, in: [original, original]))
    }
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

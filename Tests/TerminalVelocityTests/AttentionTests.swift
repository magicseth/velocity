import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class AttentionTests: XCTestCase {
    func testCodexBothBlinkPhases() {
        for mark in ["!", "."] {
            XCTAssertEqual(AgentAttention.detect(title: "project — [ \(mark) ] Action Required | task — codex", terminal: true), .needsInput)
        }
        XCTAssertEqual(AgentAttention.detect(title: "Fix Action Required title parsing — codex", terminal: true), .none)
        XCTAssertEqual(AgentAttention.detect(title: "[ ! ] Action Required | docs", terminal: false), .none)
    }
    func testClaudeIdleIsNotAnApprovalAndSpinnerIsWorking() {
        XCTAssertEqual(AgentAttention.detect(title: "~/project — ✳ Fix search — claude --resume", terminal: true), .idle)
        for marker in ["◐", "◑"] {
            XCTAssertEqual(AgentAttention.detect(title: "project — \(marker) Fix search — claude", terminal: true), .working)
        }
        XCTAssertEqual(AgentAttention.detect(title: "✳ Not an agent", terminal: true), .none)
        XCTAssertEqual(AgentAttention.detect(title: "Discuss ✳ stars — claude", terminal: true), .none)
    }
    func testWaitingSeparatesConfirmedInputFromIdle() {
        let idle = WindowEntry(id: "1", pid: 1, appName: "Terminal", title: "✳ Task — claude", icon: nil,
                               element: nil, minimized: false, hidden: false, terminal: true)
        XCTAssertFalse(SearchQuery("@attention").accepts(idle, recent: false))
        XCTAssertTrue(SearchQuery("@ready").accepts(idle, recent: false))
        XCTAssertFalse(SearchQuery("@waiting").accepts(idle, recent: false))
    }

    @MainActor func testAttentionScopeExcludesIdleAndWorking() {
        func entry(_ id: String, _ title: String) -> WindowEntry {
            WindowEntry(id: id, pid: 1, appName: "Terminal", title: title, icon: nil,
                        element: nil, minimized: false, hidden: false, terminal: true)
        }
        let waiting = entry("waiting", "[ ! ] Action Required | checkout — codex")
        let model = PaletteModel()
        model.all = [entry("idle", "✳ Task — claude"), entry("busy", "◐ Task — claude"), waiting]
        model.scope = .attention
        XCTAssertEqual(model.results.map(\.id), ["waiting"])
        XCTAssertTrue(SearchQuery("@attention").accepts(waiting, recent: false))
    }
    @MainActor func testAttentionDeduplicatesWindowAndMatchingTabOnly() {
        let window = AXUIElementCreateApplication(901)
        func entry(_ id: String, _ title: String, tab: Bool, element: AXUIElement? = nil) -> WindowEntry {
            WindowEntry(id: id, pid: 901, appName: "Terminal", title: title, icon: nil,
                        element: element ?? window, minimized: false, hidden: false, terminal: true,
                        tab: tab ? AXUIElementCreateApplication(902) : nil)
        }
        let model = PaletteModel()
        model.all = [
            entry("window", "convexos — [ . ] Action Required | Task one — codex ◂ node codex — 148×38", tab: false),
            entry("tab", "~/Projects/convexos — [ ! ] Action Required | Task one — codex ◂ node codex", tab: true),
            entry("other-tab", "[ ! ] Action Required | Task two", tab: true),
            entry("other-window", "convexos — [ ! ] Action Required | Task one", tab: false, element: AXUIElementCreateApplication(903))
        ]
        model.scope = .attention
        XCTAssertEqual(Set(model.results.map(\.id)), ["tab", "other-tab", "other-window"])
        model.scope = .all
        model.query = "@waiting"
        XCTAssertEqual(Set(model.results.map(\.id)), ["tab", "other-tab", "other-window"])
        model.query = "@windows @attention"
        XCTAssertEqual(Set(model.results.map(\.id)), ["window", "other-window"])
    }

}

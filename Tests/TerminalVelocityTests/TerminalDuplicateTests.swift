import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class TerminalDuplicateTests: XCTestCase {
    @MainActor func testAgentTaskTitleDeduplicatesDifferentWindowAndTabDecorations() {
        let parent = AXUIElementCreateApplication(501)
        let window = WindowEntry(id: "window", pid: 501, appName: "Terminal",
                                 title: "waveshare — ✳ Waveshare touch LCD car game — node ◂ claude --resume — 120×40",
                                 icon: nil, element: parent, minimized: false, hidden: false, terminal: true)
        let tab = WindowEntry(id: "tab", pid: 501, appName: "Terminal",
                              title: "~/Projects/waveshare — ◐ Waveshare touch LCD car game ◂ claude --resume",
                              icon: nil, element: parent, minimized: false, hidden: false, terminal: true,
                              tab: AXUIElementCreateApplication(502))
        let separate = WindowEntry(id: "separate", pid: 501, appName: "Terminal", title: window.title,
                                   icon: nil, element: AXUIElementCreateApplication(503), minimized: false, hidden: false, terminal: true)
        var differentTask = tab
        differentTask.title = "✳ Another task ◂ claude --resume"
        XCTAssertEqual(window.agentTaskTitle, "Waveshare touch LCD car game")
        XCTAssertEqual(window.agentTaskTitle, tab.agentTaskTitle)
        let model = PaletteModel()
        model.all = [window, tab, separate]
        model.query = "waveshare"
        XCTAssertEqual(Set(model.results.map(\.id)), ["tab", "separate"])
        model.query = "@windows waveshare"
        XCTAssertEqual(Set(model.results.map(\.id)), ["window", "separate"])
        model.all = [window, differentTask]
        model.query = ""
        XCTAssertEqual(Set(model.results.map(\.id)), ["window", "tab"])
        model.all = [window, tab]
        model.query = "node"
        XCTAssertEqual(model.results.map(\.id), ["window"])
    }

    @MainActor func testOrdinaryMinimizedTerminalWindowYieldsToItsMatchingTabOnly() {
        let window = AXUIElementCreateApplication(4001)
        func entry(_ id: String, title: String, element: AXUIElement, tab: Bool) -> WindowEntry {
            WindowEntry(id: id, pid: 4001, appName: "Terminal", title: title, icon: nil,
                        element: element, minimized: true, hidden: false, terminal: true,
                        tab: tab ? AXUIElementCreateApplication(4002) : nil)
        }
        let title = "Convex AI gateway component"
        let parent = entry("window", title: title, element: window, tab: false)
        let tab = entry("tab", title: title, element: window, tab: true)
        let otherWindow = entry("separate", title: title, element: AXUIElementCreateApplication(4003), tab: false)
        let otherTab = entry("other-tab", title: "Different task", element: window, tab: true)
        let model = PaletteModel()
        model.all = [parent, tab, otherWindow, otherTab]
        model.filter()
        XCTAssertEqual(Set(model.results.map(\.id)), ["tab", "separate", "other-tab"])
        var sized = parent
        sized.title += " — 208×53"
        model.all = [sized, tab]
        model.filter()
        XCTAssertEqual(model.results.map(\.id), ["tab"])
        model.all = [parent]
        model.filter()
        XCTAssertEqual(model.results.map(\.id), ["window"])
    }
}

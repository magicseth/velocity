import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class TerminalDuplicateTests: XCTestCase {
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

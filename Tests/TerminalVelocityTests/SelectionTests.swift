import XCTest
@testable import TerminalVelocity

final class SelectionTests: XCTestCase {
    @MainActor func testRecommittingSameSearchTextDoesNotResetSelection() {
        let model = PaletteModel()
        model.all = [entry("Terminal"), entry("Chrome")]
        model.query = "velocity"
        model.move(1)
        model.query = "velocity"
        XCTAssertEqual(model.resultState.selectedEntry?.appName, "Chrome")
        model.openAllApps()
        XCTAssertEqual(model.resultState.selectedEntry?.appName, "Terminal")
    }

    private func entry(_ id: String) -> WindowEntry {
        WindowEntry(id: id, pid: 1, appName: id, title: "velocity", icon: nil, element: nil,
                    minimized: false, hidden: false, terminal: id == "Terminal")
    }

    @MainActor func testRefreshCannotRetargetChromeSelectionToTerminal() {
        let model = PaletteModel()
        model.all = [entry("Chrome"), entry("Terminal")]
        model.query = "velocity"
        let displayed = model.resultState
        XCTAssertEqual(displayed.selectedEntry?.appName, "Chrome")
        model.all.reverse()
        model.filter(preserveSelection: true)
        XCTAssertEqual(model.resultState.selectedEntry?.appName, "Chrome")
        XCTAssertEqual(model.selected, 1)
        XCTAssertEqual(displayed.selectedEntry?.appName, "Chrome", "An already-rendered submit closure keeps its displayed destination")
        model.all = [entry("Terminal")]
        model.filter(preserveSelection: true)
        XCTAssertNil(model.resultState.selectedEntry, "A missing Chrome result must not silently select Terminal")
        model.move(1)
        XCTAssertEqual(model.resultState.selectedEntry?.appName, "Terminal")
    }

    @MainActor func testChangingQuerySelectsNewResultsAtomically() {
        let model = PaletteModel()
        model.all = [entry("Chrome"), entry("Terminal")]
        model.query = "Chrome"
        XCTAssertEqual(model.resultState.selectedEntry?.appName, "Chrome")
        model.query = "Terminal"
        XCTAssertEqual(model.resultState.entries.map(\.appName), ["Terminal"])
        XCTAssertEqual(model.resultState.selectedEntry?.appName, "Terminal")
    }
}

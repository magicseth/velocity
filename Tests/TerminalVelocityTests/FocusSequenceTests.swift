import XCTest
@testable import TerminalVelocity

final class FocusSequenceTests: XCTestCase {
    private func entry(_ id: String) -> WindowEntry {
        WindowEntry(id: id, pid: 1, appName: id, title: id, icon: nil, element: nil,
                    minimized: false, hidden: false, terminal: id == "Terminal")
    }

    @MainActor func testFailedChromeCompanionStillReachesSelectedTerminal() async {
        var visited: [String] = []
        let result = await FocusSequence.run(companions: [entry("Chrome")], selected: entry("Terminal")) { item in
            visited.append(item.id)
            return item.id == "Terminal"
        }
        XCTAssertEqual(visited, ["Chrome", "Terminal"])
        XCTAssertTrue(result.selectedFocused)
        XCTAssertFalse(result.companionsFocused)
    }

    @MainActor func testSuccessfulCompanionCannotMaskFailedDestination() async {
        var visited: [String] = []
        let result = await FocusSequence.run(companions: [entry("Chrome")], selected: entry("Terminal")) { item in
            visited.append(item.id)
            return item.id == "Chrome"
        }
        XCTAssertEqual(visited.last, "Terminal")
        XCTAssertFalse(result.selectedFocused)
        XCTAssertTrue(result.companionsFocused)
    }
}

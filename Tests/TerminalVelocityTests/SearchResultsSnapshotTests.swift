import XCTest
@testable import TerminalVelocity

final class SearchResultsSnapshotTests: XCTestCase {
    func testRowsRefreshForRetitlesAndReorderingButNotSelection() {
        func entry(_ id: String, _ title: String) -> WindowEntry {
            WindowEntry(id: id, pid: 123, appName: "Terminal", title: title, icon: nil,
                        element: nil, minimized: false, hidden: false, terminal: true)
        }
        let first = entry("one", "mcpfix — PR review and fixes")
        let second = entry("two", "terminal-velocity — Search titles")
        let original = SearchResults(entries: [first, second], selectedID: first.id)
        XCTAssertEqual(original.contentIdentity, SearchResults(entries: [first, second], selectedID: second.id).contentIdentity)
        XCTAssertNotEqual(original.contentIdentity, SearchResults(entries: [second, first], selectedID: first.id).contentIdentity)
        XCTAssertNotEqual(original.contentIdentity, SearchResults(entries: [entry("one", "Terminal"), second], selectedID: first.id).contentIdentity)
    }
}

import XCTest
@testable import TerminalVelocity

final class AIGroupingTests: XCTestCase {
    func testSmallerRetryKeepsOnlySelectedWindowsAndAtLeastTwo() {
        let candidates = (1...20).map { GroupingCandidate(id: "w\($0)", app: "App", title: "Window", folder: "", tabs: []) }
        let selected = Set(candidates.dropFirst(4).map(\.id))
        let smaller = AIGrouping.smallerSelection(candidates, selected: selected)
        XCTAssertEqual(smaller.count, 8)
        XCTAssertTrue(smaller.isSubset(of: selected))
        XCTAssertEqual(AIGrouping.smallerSelection(candidates, selected: ["w1", "w8", "w9"]), ["w1", "w8"])
    }

    func testEndpointErrorsIncludeStatusAndUsefulGuidance() {
        XCTAssertTrue(AIGrouping.responseError(status: 404, data: Data("Not found".utf8)).contains(".convex.site"))
        XCTAssertTrue(AIGrouping.responseError(status: 502, data: Data("Bad gateway".utf8)).contains("HTTP 502"))
        XCTAssertTrue(AIGrouping.responseError(status: 401, data: Data()).contains("device token"))
        XCTAssertTrue(AIGrouping.responseError(status: 502, data: Data(#"{"error":"Try fewer windows"}"#.utf8)).contains("Try fewer windows"))
    }

    func testMetadataRemovesCommandsAndURLSecrets() {
        XCTAssertEqual(AIGrouping.metadata("Project ◂ node --private", limit: 400), "Project")
        XCTAssertEqual(AIGrouping.metadata("https://example.com/project?token=private#fragment", limit: 400), "https://example.com/project")
        XCTAssertEqual(AIGrouping.metadata("project password=private", limit: 400), "project [redacted]")
        XCTAssertEqual(AIGrouping.metadata("abcdef", limit: 3), "abc")
    }
    func testUnknownAndOverlappingWindowsAreRejected() throws {
        func group(_ ids: [String]) -> SuggestedObjective {
            SuggestedObjective(name: "Project", reason: "Shared project", confidence: "high", memberIds: ids)
        }
        let known: Set<String> = ["a", "b", "c", "d"]
        try AIGrouping.validate([group(["a", "b"])], known: known)
        XCTAssertThrowsError(try AIGrouping.validate([group(["a", "unknown"])], known: known))
        XCTAssertThrowsError(try AIGrouping.validate([group(["a", "b"]), group(["b", "c"])], known: known))
        XCTAssertThrowsError(try AIGrouping.validate([group(["a", "a"])], known: known))
        XCTAssertThrowsError(try AIGrouping.validate([group(["a"])], known: known))
    }
}

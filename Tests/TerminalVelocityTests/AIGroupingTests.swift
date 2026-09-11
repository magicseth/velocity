import XCTest
@testable import TerminalVelocity

final class AIGroupingTests: XCTestCase {
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

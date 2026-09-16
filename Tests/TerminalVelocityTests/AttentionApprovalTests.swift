import XCTest
@testable import TerminalVelocity

final class AttentionApprovalTests: XCTestCase {
    func testExplicitQuestionBoundToExactTextAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 100)
        let text = "Prepare test fixture\nContinue? [y/N]"
        let approval = try XCTUnwrap(AttentionApproval.parse(text, now: now))
        XCTAssertEqual(approval.reply, .yesAndReturn)
        XCTAssertTrue(approval.matches(text, now: now.addingTimeInterval(119)))
        XCTAssertFalse(approval.matches(text, now: now.addingTimeInterval(121)))
        XCTAssertFalse(approval.matches(text, now: now.addingTimeInterval(-1)))
        XCTAssertFalse(approval.matches("Delete files\nContinue? [y/N]", now: now))
        XCTAssertFalse(approval.matches(text + "\n$ ", now: now))
    }
    func testCodexOneTimeShortcutAndUnsupportedMenus() throws {
        let text = "Would you like to run this command?\n$ echo fixture\n› 1. Yes, proceed (y)\n2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel"
        let approval = try XCTUnwrap(AttentionApproval.parse(text))
        XCTAssertEqual(approval.reply, .yesKey)
        XCTAssertTrue(approval.prompt.contains("echo fixture"))
        XCTAssertNil(AttentionApproval.parse("Yes, I can do that."))
        XCTAssertNil(AttentionApproval.parse("1. Yes\n2. No"))
        XCTAssertNil(AttentionApproval.parse(text.replacingOccurrences(of: "Yes, proceed (y)", with: "Always allow (y)")))
        XCTAssertNil(AttentionApproval.parse(text + "\nWorking…"))
        XCTAssertNil(AttentionApproval.parse("This tab is in the background. Open it to read its current prompt."))
    }
}

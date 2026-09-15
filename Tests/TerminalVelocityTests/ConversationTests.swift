import XCTest
@testable import TerminalVelocity

final class ConversationTests: XCTestCase {
    func testMessagesPreviewIsNotIndexed() {
        XCTAssertEqual(Conversations.messagesName("Alex, Unread, Private message contents, 12:00 PM"), "Alex")
        XCTAssertEqual(Conversations.messagesName("Family, Muted, Pinned"), "Family")
        XCTAssertNil(Conversations.messagesName(""))
    }
    func testSlackIdentityIncludesWorkspace() {
        XCTAssertEqual(Conversations.slackScope("https://app.slack.com/client/T123/C456"), "T123")
        XCTAssertEqual(Conversations.slackScope("app.slack.com/client/T123/C456"), "T123")
        XCTAssertNil(Conversations.slackScope("https://example.com/client/T123/C456"))
        XCTAssertNil(Conversations.slackScope("https://app.slack.com/client/invalid"))
        XCTAssertNotEqual(ConversationDestination(appID: Conversations.slackID, name: "general", scope: "T1").key,
                          ConversationDestination(appID: Conversations.slackID, name: "general", scope: "T2").key)
    }
    func testConversationCannotCloseOwningWindow() {
        let entry = WindowEntry(id: "conversation", pid: 1, appName: "Messages", title: "Alex", icon: nil,
                                element: nil, minimized: false, hidden: false, terminal: false,
                                conversation: .init(appID: Conversations.messagesID, name: "Alex", scope: ""))
        XCTAssertFalse(entry.canClose)
        XCTAssertEqual(entry.subtitle, "Messages · Conversation")
        XCTAssertNil(entry.windowKey)
    }
}

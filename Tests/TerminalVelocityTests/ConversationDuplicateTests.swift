import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class ConversationDuplicateTests: XCTestCase {
    @MainActor func testShortRecipientReplacesOnlyItsOwnWindowAndFullNameRemainsSearchable() {
        let parent = AXUIElementCreateApplication(4001)
        let window = WindowEntry(id: "window", pid: 4001, appName: "Messages", title: "Kyle Ruddick", icon: nil,
                                 element: parent, minimized: false, hidden: false, terminal: false)
        let conversation = WindowEntry(id: "conversation", pid: 4001, appName: "Messages", title: "Kyle", icon: nil,
                                       element: parent, minimized: false, hidden: false, terminal: false,
                                       conversation: .init(appID: Conversations.messagesID, name: "Kyle", scope: ""),
                                       representedWindowTitle: "Kyle Ruddick")
        let separate = WindowEntry(id: "separate", pid: 4001, appName: "Messages", title: "Kyle Ruddick", icon: nil,
                                   element: AXUIElementCreateApplication(4002), minimized: false, hidden: false, terminal: false)
        let model = PaletteModel()
        model.all = [window, conversation, separate]
        model.filter()
        XCTAssertEqual(Set(model.results.map(\.id)), ["conversation", "separate"])
        model.query = "Ruddick"
        XCTAssertEqual(Set(model.results.map(\.id)), ["conversation", "separate"])
        XCTAssertEqual(ResultDeduplication.removingRepresentedWindows([window]).map(\.id), ["window"])
        var unrelated = conversation
        unrelated.representedWindowTitle = nil
        XCTAssertEqual(ResultDeduplication.removingRepresentedWindows([window, unrelated]).count, 2)
        var stale = conversation
        stale.representedWindowTitle = "Previous conversation"
        XCTAssertEqual(ResultDeduplication.removingRepresentedWindows([window, stale]).count, 2)
    }
}

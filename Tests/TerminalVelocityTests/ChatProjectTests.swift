import XCTest
@testable import TerminalVelocity

final class ChatProjectTests: XCTestCase {
    func testStableURLNeverFallsBackToSameNamedProject() {
        let target = ChatProject(name: "Work", mode: "Chat / Cowork", url: "https://claude.ai/project/one")
        XCTAssertFalse(ChatProjects.matches(target, candidate: .init(name: "Work", mode: target.mode, url: "https://claude.ai/project/two")))
        XCTAssertTrue(ChatProjects.matches(target, candidate: .init(name: "Renamed", mode: target.mode, url: target.url)))
        XCTAssertFalse(ChatProjects.matches(target, candidate: .init(name: "Work", mode: "Code", url: target.url)))
    }
    func testProjectLabelsExcludeNavigationAndSessionTitles() {
        XCTAssertEqual(ChatProjects.projectName("Toggle chats for abstract magic"), "abstract magic")
        XCTAssertEqual(ChatProjects.projectName("Toggle sessions for Discovery"), "Discovery")
        XCTAssertEqual(ChatProjects.projectName("New session in dateme"), "dateme")
        XCTAssertNil(ChatProjects.projectName("Projects"))
        XCTAssertNil(ChatProjects.projectName("Idle Build an app"))
    }
    func testOnlyClaudeProjectDestinationsAreIndexed() {
        XCTAssertTrue(ChatProjects.isProjectURL("https://claude.ai/cowork/project/123"))
        XCTAssertTrue(ChatProjects.isProjectURL("claude.ai/space/123"))
        XCTAssertFalse(ChatProjects.isProjectURL("https://example.com/project/123"))
        XCTAssertFalse(ChatProjects.isProjectURL("claude.ai/chat/123"))
        XCTAssertFalse(ChatProjects.isProjectURL("claude.ai/projects"))
        let project = ChatProject(name: "Example", mode: "Code", url: nil)
        let entry = WindowEntry(id: "project", pid: 1, appName: "Claude", title: project.name, icon: nil,
            element: nil, minimized: false, hidden: false, terminal: false, chatProject: project)
        XCTAssertEqual(entry.subtitle, "Claude · Project · Code")
        XCTAssertNil(entry.windowKey)
    }
}

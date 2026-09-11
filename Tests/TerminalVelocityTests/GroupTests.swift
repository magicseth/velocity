import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class GroupTests: XCTestCase {
    private func window(_ pid: pid_t, tab: Bool = false) -> WindowEntry {
        let element = AXUIElementCreateApplication(pid)
        return WindowEntry(id: "\(pid)-\(tab)", pid: pid, appName: "Test", title: "Same title", icon: nil,
                           element: element, minimized: false, hidden: false, terminal: false,
                           tab: tab ? element : nil)
    }

    func testGroupsUseWindowIdentityAndDeduplicateTabs() {
        let first = window(100), second = window(200), unrelated = window(300)
        let group = WindowGroup(id: UUID(), name: "Project", members: [first.windowKey!, second.windowKey!])
        let companions = WindowGroup.companions(of: first, groups: [group],
            entries: [first, window(200, tab: true), second, second, unrelated])
        XCTAssertEqual(companions.map(\.id), [second.id])
        XCTAssertTrue(WindowGroup.companions(of: unrelated, groups: [group], entries: [first, second]).isEmpty)
    }

    @MainActor func testReassignmentAndDissolving() {
        let model = PaletteModel()
        model.groups = [WindowGroup(id: UUID(), name: "Old", members: ["a", "b", "c"])]
        model.groupName = "New"
        model.groupMembers = ["c", "d"]
        model.saveGroup()
        if !Features.experimentalAgents {
            XCTAssertEqual(model.groups.count, 1)
            XCTAssertEqual(model.groups.first?.members, ["a", "b", "c"])
            return
        }
        XCTAssertEqual(model.groups.count, 2)
        XCTAssertEqual(model.groups.first?.members, ["a", "b"])
        model.editingGroupID = model.groups.last?.id
        model.groupMembers = ["b", "d"]
        model.saveGroup()
        XCTAssertEqual(model.groups.count, 1, "An old group with only one remaining window is dissolved")
        XCTAssertEqual(model.groups.first?.members, ["b", "d"])
    }
}

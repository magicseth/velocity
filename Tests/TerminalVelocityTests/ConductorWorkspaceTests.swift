import XCTest
@testable import TerminalVelocity

final class ConductorWorkspaceTests: XCTestCase {
    func testOnlyExactConductorWorkspaceRoutesAreAccepted() {
        let route = "tauri://localhost/repository/6627faf8-1c43-4bfe-aaed-b677765c6784/workspace/0327148b-caca-41dd-b6af-89b83bebe128"
        XCTAssertEqual(ConductorWorkspaces.workspaceRoute(route), route)
        for invalid in [route.replacingOccurrences(of: "localhost", with: "evil.example"),
                        route.replacingOccurrences(of: "tauri:", with: "https:"), route + "/delete", route + "?archive=true",
                        "tauri://localhost/repository/invalid/workspace/invalid"] {
            XCTAssertNil(ConductorWorkspaces.workspaceRoute(invalid))
        }
    }
    func testStripOnlyTrailingDiffBadges() {
        XCTAssertEqual(ConductorWorkspaces.workspaceName("Fix build\n\n+5.1k -16"), "Fix build")
        XCTAssertEqual(ConductorWorkspaces.workspaceName("CLI update -✱✱"), "CLI update")
        XCTAssertEqual(ConductorWorkspaces.workspaceName("Support C++ and -flags"), "Support C++ and -flags")
    }
    @MainActor func testLaunchAppsStayBelowRunningMatchesEvenWhenRecentlyUsed() {
        let defaults = UserDefaults(suiteName: "LaunchOrdering.\(UUID())")!
        let memory = SelectionMemory(defaults: defaults)
        let model = PaletteModel(memory: memory)
        var launch = WindowEntry(id: "launch", pid: 0, appName: "Mail", title: "Mail", icon: nil,
                                 element: nil, minimized: false, hidden: false, terminal: false)
        launch.launchURL = URL(fileURLWithPath: "/Applications/Mail.app")
        let window = WindowEntry(id: "open", pid: 1, appName: "Chrome", title: "My mail inbox", icon: nil,
                                element: nil, minimized: false, hidden: false, terminal: false)
        memory.record(launch.memoryKey)
        model.all = [launch, window]
        model.openAllApps()
        XCTAssertEqual(model.results.map(\.id), ["open", "launch"])
        model.query = "mail"
        XCTAssertEqual(model.results.map(\.id), ["open", "launch"])
    }
}

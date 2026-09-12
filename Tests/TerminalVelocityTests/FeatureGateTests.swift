import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class FeatureGateTests: XCTestCase {
    @MainActor func testPublicBuildCannotStartGrouping() {
        let model = PaletteModel()
        model.beginAIGrouping()
        XCTAssertEqual(model.showAIGrouping, Features.experimentalAgents)
        if !Features.experimentalAgents {
            let entry = WindowEntry(id: "sample", pid: 100001, appName: "Terminal", title: "[ ! ] Action Required | Ship checkout — codex",
                icon: nil, element: AXUIElementCreateApplication(100001), minimized: false, hidden: false, terminal: true)
            model.editGroup(entry)
            model.requestAIGrouping()
            XCTAssertFalse(model.editingGroup)
            XCTAssertFalse(model.aiLoading)
            XCTAssertEqual(entry.displayTitle, entry.title)
        }
    }

    func testExperimentalSynopsisPreservesOriginalTitle() {
        let entry = WindowEntry(id: "sample", pid: 1, appName: "Terminal", title: "[ ! ] Action Required | Ship checkout — codex",
            icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        XCTAssertEqual(entry.displayTitle, Features.experimentalAgents ? "Ship checkout" : entry.title)
        XCTAssertTrue(entry.searchText.contains("Action Required"))
    }

    func testPublicGatewayRejectsBeforeNetworking() async {
        guard !Features.experimentalAgents else { return }
        do {
            _ = try await AIGrouping.classify(ClassificationRequest(candidates: [], overview: [], objectives: []), endpoint: "not-a-url", token: "")
            XCTFail("Public builds must reject AI requests")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disabled in this build"))
        }
    }
}

import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class GroupingScanTests: XCTestCase {
    private func candidates(_ count: Int) -> [GroupingCandidate] {
        (1...count).map { GroupingCandidate(id: "w\($0)", app: $0 % 2 == 0 ? "Browser" : "Terminal",
                                          title: "Project \($0)", folder: "Projects", tabs: []) }
    }
    private func assignment(_ ids: [String], objective: String? = nil) -> ObjectiveAssignment {
        ObjectiveAssignment(objectiveID: objective, name: "Checkout", reason: "Shared checkout project", confidence: "high", memberIds: ids)
    }
    func testEveryWindowIsProcessedAndDistantBatchesShareAnObjective() throws {
        var scan = GroupingScan(candidates: candidates(161), endpoint: "endpoint")
        var seen: [String] = []
        while !scan.complete {
            let request = try scan.nextRequest()
            XCTAssertEqual(request.overview.count, 161)
            seen += request.candidates.map(\.id)
            let output: [ObjectiveAssignment]
            if scan.processed == 0 { output = [assignment(["w1"])] }
            else if request.candidates.contains(where: { $0.id == "w161" }) {
                XCTAssertEqual(request.objectives.first?.id, "g1")
                output = [assignment(["w161"], objective: "g1")]
            } else { output = [] }
            try scan.accept(output, for: request)
        }
        XCTAssertEqual(seen, candidates(161).map(\.id))
        XCTAssertEqual(scan.suggestions.first?.memberIds, ["w1", "w161"])
    }
    func testFailedBatchDoesNotAdvanceOrCorruptCheckpointAndSmallerRetryDropsNothing() throws {
        var scan = GroupingScan(candidates: candidates(83), endpoint: "endpoint")
        try scan.accept([assignment(["w1"])], for: scan.nextRequest())
        let request = try scan.nextRequest()
        XCTAssertThrowsError(try scan.accept([assignment(["w41"], objective: "g1"), assignment(["w1"])], for: request))
        XCTAssertEqual(scan.processed, 40)
        XCTAssertEqual(scan.proposals.first?.memberIds, ["w1"])
        scan.batchSize = 20
        var remaining: [String] = []
        while !scan.complete {
            let batch = try scan.nextRequest()
            remaining += batch.candidates.map(\.id)
            try scan.accept([], for: batch)
        }
        XCTAssertEqual(remaining, candidates(83).dropFirst(40).map(\.id))
    }
    func testRejectsInventedObjectivesAndOverlappingBatchMembership() throws {
        var scan = GroupingScan(candidates: candidates(2), endpoint: "endpoint")
        let request = try scan.nextRequest()
        XCTAssertThrowsError(try scan.accept([assignment(["w1"], objective: "unknown")], for: request))
        XCTAssertThrowsError(try scan.accept([assignment(["w1"]), assignment(["w1", "w2"])], for: request))
        XCTAssertEqual(scan.processed, 0)
        XCTAssertTrue(scan.catalog.isEmpty)
    }
    @MainActor func testCandidateCollectionDoesNotTruncateWindowsOrTabContext() {
        guard Features.experimentalAgents else { return }
        let model = PaletteModel()
        model.groups = []
        model.all = (1...145).map {
            WindowEntry(id: "w\($0)", pid: Int32(100000 + $0), appName: "App", title: "Window \($0)", icon: nil,
                        element: AXUIElementCreateApplication(Int32(100000 + $0)), minimized: false, hidden: false, terminal: false)
        }
        let first = model.all[0]
        model.all += (1...25).map {
            WindowEntry(id: "t\($0)", pid: first.pid, appName: first.appName, title: "Tab \($0)", icon: nil,
                        element: first.element, minimized: false, hidden: false, terminal: false,
                        tab: AXUIElementCreateApplication(Int32(200000 + $0)))
        }
        model.beginAIGrouping()
        XCTAssertEqual(model.aiCandidates.count, 145)
        XCTAssertEqual(model.aiSelectedCandidates.count, 145)
        XCTAssertEqual(model.aiCandidates.first?.tabs.count, 25)
    }
}

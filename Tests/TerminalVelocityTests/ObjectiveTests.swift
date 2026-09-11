import XCTest
@testable import TerminalVelocity

final class ObjectiveTests: XCTestCase {
    func testHandoffsRequireObservedWorkAndDonePersists() {
        let suite = "ObjectiveTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = ObjectiveLedger(defaults: defaults)
        var entry = WindowEntry(id: "stable", pid: 1, appName: "Terminal", title: "✳ Task — claude", icon: nil,
                                element: nil, minimized: false, hidden: false, terminal: true)
        ledger.observe(id: "objective", entry: entry)
        XCTAssertNil(ledger.records["objective"], "An initially idle agent is not automatically unread")
        entry.title = "◐ Task — claude"
        ledger.observe(id: "objective", entry: entry)
        entry.title = "✳ Task — claude"
        ledger.observe(id: "objective", entry: entry)
        XCTAssertEqual(ledger.records["objective"]?.unread, true)
        ledger.update("objective") { $0.unread = false; $0.done = true }
        ledger.observe(id: "objective", entry: entry)
        XCTAssertEqual(ledger.records["objective"]?.unread, false)
        let restored = ObjectiveLedger(defaults: defaults)
        XCTAssertEqual(restored.records["objective"]?.done, true)
    }
    @MainActor func testDoneRequiresExplicitRecall() {
        let model = PaletteModel()
        let group = WindowGroup(id: UUID(), name: "Checkout", members: [])
        model.groups = [group]
        let item = model.objectiveItems.first!
        model.markObjective(item, done: true)
        defer { model.ledger.update(item.id) { $0.done = false } }
        XCTAssertTrue(model.objectiveItems.isEmpty)
        model.objectiveQuery = "Checkout"
        XCTAssertTrue(model.objectiveItems.isEmpty)
        model.objectiveQuery = "@done Checkout"
        XCTAssertEqual(model.objectiveItems.map(\.id), [item.id])
        model.markObjective(item, done: false)
        model.objectiveQuery = ""
        XCTAssertEqual(model.objectiveItems.map(\.id), [item.id])
    }
}

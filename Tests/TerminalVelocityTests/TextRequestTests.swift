import XCTest
import ApplicationServices
@testable import TerminalVelocity

@MainActor final class TextRequestTests: XCTestCase {
    private func entry(_ title: String = "Waveshare", id: String = "one") -> WindowEntry {
        WindowEntry(id: id, pid: 900001, appName: "Terminal", title: title, icon: nil,
                    element: AXUIElementCreateApplication(900001), minimized: false, hidden: false, terminal: true)
    }
    func testLocalOpenRequiresAuthenticationAndDoesNotGrantExternalAccess() async throws {
        var opened = 0
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, action in
            XCTAssertEqual(action, .open); opened += 1; return true
        }
        broker.reconcile([entry()])
        let target = broker.resources[0]
        do { _ = try await broker.openLocally(target, proposedAt: Date()) { false }; XCTFail() } catch {}
        XCTAssertEqual(opened, 0)
        let success = try await broker.openLocally(target, proposedAt: Date()) { true }
        XCTAssertTrue(success)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(broker.agents.isEmpty)
        XCTAssertTrue(broker.grants.isEmpty)
        XCTAssertNil(broker.resources[0].projectID)
        XCTAssertTrue(broker.audit.contains { $0.event == "local.open.biometricApproved" })
    }
    func testTargetChangesDuringAuthenticationFailClosed() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail("Stale target opened"); return true }
        broker.reconcile([entry()])
        let target = broker.resources[0]
        do {
            _ = try await broker.openLocally(target, proposedAt: Date()) {
                broker.reconcile([self.entry("Different tab")]); return true
            }
            XCTFail("Stale proposal accepted")
        } catch {}
    }
    func testExpiryBlockAndAuditFailurePreventAuthenticationAndExecution() async throws {
        var failAudit = false
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in if failAudit { throw AccessError.storage } }) { _, _ in XCTFail(); return true }
        broker.reconcile([entry()])
        let target = broker.resources[0]
        do { _ = try await broker.openLocally(target, proposedAt: Date().addingTimeInterval(-301)) { XCTFail(); return true }; XCTFail() } catch {}
        try broker.assign(target.id, project: nil, safety: .blocked)
        do { _ = try await broker.openLocally(broker.resources[0], proposedAt: Date()) { XCTFail(); return true }; XCTFail() } catch {}
        try broker.assign(target.id, project: nil, safety: .ask)
        failAudit = true
        do { _ = try await broker.openLocally(broker.resources[0], proposedAt: Date()) { XCTFail(); return true }; XCTFail() } catch {}
    }
    func testModelCannotInventTargetsOrActions() throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in false }
        broker.reconcile([entry(), entry("Other", id: "two")])
        let snapshot = broker.resources
        let ids = snapshot.map(\.id)
        XCTAssertEqual(try OpenProposal(message: "Choose", candidates: ids).resolve(in: snapshot).count, 2)
        XCTAssertThrowsError(try OpenProposal(message: "Oops", candidates: [UUID()]).resolve(in: snapshot))
        XCTAssertThrowsError(try OpenProposal(message: "Oops", candidates: [ids[0], ids[0]]).resolve(in: snapshot))
        XCTAssertTrue(try OpenProposal(message: "Unsupported request", candidates: []).resolve(in: snapshot).isEmpty)
    }
}

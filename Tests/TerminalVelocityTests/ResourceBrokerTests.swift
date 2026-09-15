import XCTest
import ApplicationServices
@testable import TerminalVelocity

@MainActor final class ResourceBrokerTests: XCTestCase {
    func entry(_ title: String = "Document", id: String = "one") -> WindowEntry {
        WindowEntry(id: id, pid: 900001, appName: "Test", title: title, icon: nil,
                    element: AXUIElementCreateApplication(900001), minimized: false, hidden: false, terminal: false)
    }
    func setup(_ broker: ResourceBroker) throws -> (UUID, String, ManagedResource) {
        try broker.addProject(name: "Project")
        let project = try XCTUnwrap(broker.projects.first?.id)
        let token = try broker.pair(name: "Agent", project: project)
        let agent = try broker.authenticate(token)
        broker.reconcile([entry()])
        let resource = try XCTUnwrap(broker.resources.first)
        try broker.assign(resource.id, project: project, safety: .ask)
        return (agent, token, try XCTUnwrap(broker.resources.first))
    }
    func submit(_ broker: ResourceBroker, _ agent: UUID, _ resource: ManagedResource, action: ResourceAction = .open, nonce: UUID = UUID()) async throws -> ActionRequest {
        try await broker.submit(agent: agent, resource: resource.id, revision: resource.revision, action: action, nonce: nonce, reason: "Test")
    }
    func testNoDiscoveryBeforeAssignmentAndNoActionBeforeApproval() async throws {
        var executions = 0
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in executions += 1; return true }
        try broker.addProject(name: "A")
        let project = broker.projects[0].id
        let token = try broker.pair(name: "Agent", project: project)
        let agent = try broker.authenticate(token)
        broker.reconcile([entry()])
        XCTAssertTrue(try broker.list(agent: agent).isEmpty)
        let resource = broker.resources[0]
        do { _ = try await submit(broker, agent, resource); XCTFail("Unassigned resource authorized") } catch {}
        try broker.assign(resource.id, project: project, safety: .ask)
        let request = try await submit(broker, agent, broker.resources[0])
        XCTAssertEqual(request.status, .pending)
        XCTAssertEqual(executions, 0)
        try await broker.approve(request.id)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(try broker.request(request.id, agent: agent).status, .succeeded)
        do { try await broker.approve(request.id); XCTFail("Reused approval") } catch {}
        XCTAssertEqual(executions, 1)
    }
    func testCrossProjectBlockedAndRevokedIdentitiesCannotDiscoverOrAct() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail("Unexpected execution"); return true }
        let (agent, token, resource) = try setup(broker)
        try broker.addProject(name: "Other")
        let otherToken = try broker.pair(name: "Other agent", project: broker.projects[1].id)
        let other = try broker.authenticate(otherToken)
        XCTAssertTrue(try broker.list(agent: other).isEmpty)
        do { _ = try await submit(broker, other, resource); XCTFail("Cross-project access") } catch {}
        try broker.assign(resource.id, project: resource.projectID, safety: .blocked)
        XCTAssertTrue(try broker.list(agent: agent).isEmpty)
        do { _ = try await submit(broker, agent, broker.resources[0]); XCTFail("Blocked access") } catch {}
        broker.revokeAgent(agent)
        XCTAssertThrowsError(try broker.authenticate(token))
        XCTAssertThrowsError(try broker.list(agent: agent))
    }
    func testNonceReplayReturnsOriginalAndCannotRetarget() async throws {
        var executions = 0
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in executions += 1; return true }
        let (agent, _, resource) = try setup(broker)
        let nonce = UUID()
        let request = try await submit(broker, agent, resource, nonce: nonce)
        try await broker.approve(request.id)
        let replay = try await submit(broker, agent, resource, nonce: nonce)
        XCTAssertEqual(replay.id, request.id)
        XCTAssertEqual(executions, 1)
        do { _ = try await submit(broker, agent, resource, action: .close, nonce: nonce); XCTFail("Nonce reused for another action") } catch {}
    }
    func testResourceChangeRetiresScopeGrantsAndPendingApproval() async throws {
        var executions = 0
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in executions += 1; return true }
        let (agent, _, resource) = try setup(broker)
        let request = try await submit(broker, agent, resource)
        broker.reconcile([entry("Different document")])
        XCTAssertNil(broker.resources[0].projectID)
        XCTAssertNotEqual(broker.resources[0].revision, resource.revision)
        do { try await broker.approve(request.id); XCTFail("Stale approval") } catch {}
        XCTAssertEqual(executions, 0)
        let oldID = broker.resources[0].id
        broker.reconcile([])
        broker.reconcile([entry("Different document")])
        XCTAssertNotEqual(broker.resources[0].id, oldID)
        XCTAssertNil(broker.resources[0].projectID)
    }
    func testExactOpenGrantExpiresAndNeverAuthorizesClose() async throws {
        var now = Date(), executions = 0
        let broker = ResourceBroker(storage: nil, clock: { now }, writeAudit: { _ in }) { _, _ in executions += 1; return true }
        let (agent, _, resource) = try setup(broker)
        let first = try await submit(broker, agent, resource)
        try await broker.approve(first.id, allowOpenForHour: true)
        let second = try await submit(broker, agent, resource)
        XCTAssertEqual(second.status, .succeeded)
        let close = try await submit(broker, agent, resource, action: .close)
        XCTAssertEqual(close.status, .pending)
        XCTAssertEqual(executions, 2)
        now = now.addingTimeInterval(3601)
        XCTAssertEqual(try broker.request(close.id, agent: agent).status, .expired)
        let expired = try await submit(broker, agent, resource)
        XCTAssertEqual(expired.status, .pending)
        do { try await broker.approve(close.id); XCTFail("Expired pending request") } catch {}
    }
    func testProcessRestartCannotReuseAResourceApproval() async throws {
        var process = "original"
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }, processIdentity: { _ in process }) { _, _ in XCTFail("Reused process identity"); return true }
        let (agent, _, resource) = try setup(broker)
        let request = try await submit(broker, agent, resource)
        process = "replacement"
        do { try await broker.approve(request.id); XCTFail("PID reuse accepted") } catch {}
        broker.reconcile([entry()])
        XCTAssertNotEqual(broker.resources[0].id, resource.id)
        XCTAssertNil(broker.resources[0].projectID)
    }
    func testGrantRevocationAndStopRemoveAuthority() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in true }
        let (agent, _, resource) = try setup(broker)
        let first = try await submit(broker, agent, resource)
        try await broker.approve(first.id, allowOpenForHour: true)
        broker.revokeGrant(try XCTUnwrap(broker.grants.first?.id))
        let next = try await submit(broker, agent, resource)
        XCTAssertEqual(next.status, .pending)
        broker.suspend()
        XCTAssertEqual(try broker.request(next.id, agent: agent).status, .denied)
        XCTAssertTrue(broker.grants.isEmpty)
    }
    func testAuditFailureFailsClosedBeforeDispatch() async throws {
        var fail = false, executions = 0
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in if fail { throw AccessError.storage } }) { _, _ in executions += 1; return true }
        let (agent, token, resource) = try setup(broker)
        let request = try await submit(broker, agent, resource)
        fail = true
        do { try await broker.approve(request.id); XCTFail("Missing audit accepted") } catch {}
        XCTAssertEqual(executions, 0)
        XCTAssertNotNil(broker.issue)
        XCTAssertThrowsError(try broker.authenticate(token))
    }
    func testPendingRequestsArePrivateAndBounded() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in true }
        let (agent, _, resource) = try setup(broker)
        let token = try broker.pair(name: "Second", project: resource.projectID!)
        let other = try broker.authenticate(token)
        let request = try await submit(broker, agent, resource)
        XCTAssertThrowsError(try broker.request(request.id, agent: other))
        for _ in 0..<19 { _ = try await submit(broker, agent, resource) }
        do { _ = try await submit(broker, agent, resource); XCTFail("Unbounded approval spam") } catch {}
    }
    func testUnsupportedCloseAndScopeChangesCannotInheritApproval() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail("Unexpected action"); return true }
        let (agent, _, resource) = try setup(broker)
        let request = try await submit(broker, agent, resource)
        try broker.assign(resource.id, project: nil, safety: .ask)
        do { try await broker.approve(request.id); XCTFail("Scope removed after request") } catch {}
        var conversation = entry()
        conversation.conversation = .init(appID: Conversations.messagesID, name: "Person", scope: "")
        broker.reconcile([conversation])
        try broker.assign(broker.resources[0].id, project: broker.projects[0].id, safety: .ask)
        XCTAssertTrue(broker.resources[0].capabilities.isEmpty)
        do { _ = try await submit(broker, agent, broker.resources[0], action: .close); XCTFail("Unsupported capability") } catch {}
        do { _ = try await submit(broker, agent, broker.resources[0]); XCTFail("Name-only action") } catch {}
    }
    func testRevocationPersistsEvenIfAuditAppendFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try AccessStorage(directory: directory)
        var fail = false
        let broker = ResourceBroker(storage: storage, writeAudit: { _ in if fail { throw AccessError.storage } }) { _, _ in true }
        let (agent, token, _) = try setup(broker)
        fail = true
        broker.revokeAgent(agent)
        let restarted = ResourceBroker(storage: storage) { _, _ in true }
        XCTAssertThrowsError(try restarted.authenticate(token))
    }
    func testOnlyOneStorageOwnerCanManagePersistentIdentities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try AccessStorage(directory: directory)
        try withExtendedLifetime(first) { XCTAssertThrowsError(try AccessStorage(directory: directory)) }
    }
    func testOnlyHashesPersistAndRestartDoesNotRestoreGrantsOrScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try AccessStorage(directory: directory)
        let broker = ResourceBroker(storage: storage) { _, _ in true }
        let (agent, token, resource) = try setup(broker)
        let request = try await submit(broker, agent, resource)
        try await broker.approve(request.id, allowOpenForHour: true)
        let config = try String(contentsOf: directory.appendingPathComponent("identities.json"))
        XCTAssertFalse(config.contains(token))
        XCTAssertTrue(config.contains(AccessStorage.digest(token)))
        let restarted = ResourceBroker(storage: storage) { _, _ in true }
        XCTAssertEqual(try restarted.authenticate(token), agent)
        restarted.reconcile([entry()])
        XCTAssertNil(restarted.resources[0].projectID)
        XCTAssertTrue(restarted.grants.isEmpty)
        XCTAssertTrue(restarted.requests.isEmpty)
        let audit = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"))
        XCTAssertTrue(audit.contains("action.executing"))
        XCTAssertTrue(audit.contains("action.succeeded"))
        XCTAssertFalse(audit.contains(token))
    }
}

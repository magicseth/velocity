import XCTest
@testable import TerminalVelocity

final class DirectoryBridgeTests: XCTestCase {
    @MainActor func fixture(inspector: @escaping (String) async throws -> Data = { path in try JSONSerialization.data(withJSONObject: ["directory":path, "fingerprint":String(repeating: "a", count: 64), "items":[["id":"entries"]]]) }) throws -> (URL, ResourceBroker, DirectoryBridge, String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        let inventory = root.appendingPathComponent("inventory.json")
        try JSONSerialization.data(withJSONObject: ["nodes":[["kind":"project", "path":root.appendingPathComponent("project").path]]]).write(to: inventory)
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail("directory access must not execute UI actions"); return false }
        let bridge = try DirectoryBridge(broker: broker, directory: root, inspector: inspector)
        try bridge.enroll(inventory: inventory, launch: root.appendingPathComponent("launch.json"), allowedHome: root)
        return (root, broker, bridge, bridge.state!.token)
    }
    @MainActor func testScopesStaleTargetsPrivatePersistenceAndRevocation() async throws {
        let (root, broker, bridge, token) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try broker.authenticate(token)
        XCTAssertTrue(broker.agents[0].projects.isEmpty)
        let catalog = try await bridge.discover(agent: agent)
        let ref = try XCTUnwrap(catalog.resources.first?.ref)
        let result = try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: ref.resourceId, revision: ref.revision, request: UUID())
        XCTAssertEqual(result.source, "velocity")
        XCTAssertEqual(result.actualEffects, ["read-metadata", "read-source"])
        do { _ = try await bridge.inspection(agent: agent, scopeRevision: UUID(), resource: ref.resourceId, revision: ref.revision, request: UUID()); XCTFail("wrong scope") } catch {}
        do { _ = try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: UUID(), revision: ref.revision, request: UUID()); XCTFail("wrong id") } catch {}
        try Data("modified".utf8).write(to: root.appendingPathComponent("project/README.md"))
        do { _ = try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: ref.resourceId, revision: ref.revision, request: UUID()); XCTFail("stale revision") } catch {}
        try bridge.publish(endpoint: "http://127.0.0.1:1234/v1/access")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("launch.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restored = try DirectoryBridge(broker: broker, directory: root)
        XCTAssertEqual(restored.state?.deviceId, catalog.deviceId)
        XCTAssertNotEqual(restored.epoch, catalog.epoch)
        broker.revokeAgent(agent)
        do { _ = try await bridge.discover(agent: agent); XCTFail("revoked") } catch {}
        XCTAssertThrowsError(try bridge.publish(endpoint: "http://127.0.0.1:1234/v1/access"))
    }
    @MainActor func testRejectsUnknownRemoteFieldsAndOtherAgents() async throws {
        let (root, broker, bridge, token) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AccessServer(broker: broker); server.directoryBridge = bridge
        for body in ["{\"operation\":\"directory.discover\",\"protocol\":\"velocity/1\",\"path\":\"/\"}", "{\"operation\":\"directory.discover\"}", "{\"operation\":\"directory.discover\",\"protocol\":\"velocity/1\",\"approved\":true}", "{\"operation\":\"directory.enroll\",\"protocol\":\"velocity/1\"}"] {
            let response = await server.handle(.init(token: token, body: Data(body.utf8)))
            XCTAssertNotNil(response.error)
            XCTAssertEqual(response.errorClass, "unsupported")
        }
        let other = try broker.pairDirectoryReader()
        do { _ = try await bridge.discover(agent: other.id); XCTFail("other agent") } catch {}
        let valid = await server.handle(.init(token: token, body: Data("{\"operation\":\"directory.discover\",\"protocol\":\"velocity/1\"}".utf8)))
        XCTAssertNil(valid.error); XCTAssertEqual(valid.directoryCatalog?.resources.count, 1)
    }
    @MainActor func testRechecksRevocationAfterReadAndLimitsParallelReads() async throws {
        var waits: [CheckedContinuation<Data, Error>] = []
        let (root, broker, bridge, token) = try fixture { _ in try await withCheckedThrowingContinuation { waits.append($0) } }
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try broker.authenticate(token), catalog = try await bridge.discover(agent: agent), ref = catalog.resources[0].ref
        let tasks = (0..<4).map { _ in Task { try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: ref.resourceId, revision: ref.revision, request: UUID()) } }
        for _ in 0..<100 where waits.count < 4 { await Task.yield() }
        XCTAssertEqual(waits.count, 4)
        do { _ = try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: ref.resourceId, revision: ref.revision, request: UUID()); XCTFail("fifth read") } catch {}
        broker.revokeAgent(agent)
        for wait in waits { wait.resume(returning: Data("{}".utf8)) }
        for task in tasks { do { _ = try await task.value; XCTFail("revoked in flight") } catch {} }
    }
    @MainActor func testSymlinkReplacementCannotInheritScope() async throws {
        let (root, broker, bridge, token) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try broker.authenticate(token), catalog = try await bridge.discover(agent: agent), ref = catalog.resources[0].ref
        try FileManager.default.moveItem(at: root.appendingPathComponent("project"), to: root.appendingPathComponent("other"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project"), withDestinationURL: root.appendingPathComponent("other"))
        let missing = try await bridge.discover(agent: agent); XCTAssertFalse(missing.resources[0].available)
        do { _ = try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: ref.resourceId, revision: ref.revision, request: UUID()); XCTFail("symlink replacement") } catch {}
    }
    @MainActor func testMalformedEvidenceAndReplacementDirectoriesFailClosed() async throws {
        let (root, broker, bridge, token) = try fixture { _ in Data("{}".utf8) }
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try broker.authenticate(token), catalog = try await bridge.discover(agent: agent), ref = catalog.resources[0].ref
        do { _ = try await bridge.inspection(agent: agent, scopeRevision: catalog.scopeRevision, resource: ref.resourceId, revision: ref.revision, request: UUID()); XCTFail("missing evidence provenance") } catch {}
        XCTAssertTrue(broker.audit.contains { $0.event == "directory.inspection.started" && $0.resourceID == ref.resourceId })
        XCTAssertFalse(broker.audit.contains { $0.event == "directory.inspection.completed" })
        try FileManager.default.moveItem(at: root.appendingPathComponent("project"), to: root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: false)
        let changed = try await bridge.discover(agent: agent)
        XCTAssertFalse(changed.resources[0].available)
    }

}

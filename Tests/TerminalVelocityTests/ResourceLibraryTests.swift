import XCTest
import ApplicationServices
import SQLite3
@testable import TerminalVelocity

@MainActor final class ResourceLibraryTests: XCTestCase {
    func entry(_ title: String = "~/Projects/atlas — build", id: String = "one") -> WindowEntry {
        WindowEntry(id: id, pid: 900001, appName: "Terminal", title: title, icon: nil,
                    element: AXUIElementCreateApplication(900001), minimized: false, hidden: false, terminal: true)
    }
    func broker() -> ResourceBroker {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail("Inspection must not execute"); return false }
        broker.reconcile([entry()]); return broker
    }
    func testNestedProjectsPersistAndCyclesFailWithoutMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json")
        let library = ResourceLibrary(file: file)
        let root = try library.create(name: "Work", parent: nil)
        let child = try library.create(name: "Atlas", parent: root)
        let key = AccessStorage.digest("resource")
        try library.assign(key: key, project: child)
        XCTAssertThrowsError(try library.move(root, under: child))
        XCTAssertThrowsError(try library.move(child, under: UUID()))
        XCTAssertEqual(library.path(child), "Work / Atlas")
        XCTAssertThrowsError(try library.create(name: "atlas", parent: root))
        let restored = ResourceLibrary(file: file)
        XCTAssertEqual(restored.configuration.assignments[key], child)
        XCTAssertEqual(restored.path(child), "Work / Atlas")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        try restored.remove(root)
        XCTAssertTrue(restored.configuration.projects.isEmpty)
        XCTAssertTrue(restored.configuration.assignments.isEmpty)
    }
    func testInvalidStoredHierarchyCannotBeOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let invalid = Data("{\"version\":999,\"projects\":[],\"assignments\":{}}".utf8)
        try invalid.write(to: file)
        let library = ResourceLibrary(file: file)
        XCTAssertNotNil(library.issue)
        XCTAssertThrowsError(try library.create(name: "Work", parent: nil))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
    func testOrganizationDoesNotChangeAgentScopeAndStaleReviewIsAtomic() throws {
        let broker = broker(), library = ResourceLibrary(file: nil)
        let original = broker.resources[0]
        let suggestions = ResourceLibrary.suggestions(broker: broker)
        XCTAssertEqual(suggestions.count, 1)
        try library.apply(suggestions, broker: broker)
        XCTAssertEqual(library.configuration.projects.count, 1)
        XCTAssertEqual(broker.resources[0], original)
        XCTAssertNil(broker.resources[0].projectID)
        XCTAssertTrue(broker.grants.isEmpty)
        broker.reconcile([entry("~/Projects/other — build")])
        let fresh = ResourceLibrary(file: nil)
        XCTAssertThrowsError(try fresh.apply(suggestions, broker: broker))
        XCTAssertTrue(fresh.configuration.projects.isEmpty)
        XCTAssertTrue(fresh.configuration.assignments.isEmpty)
    }
    func testInspectionReportsEvidenceAndRejectsBlockedOrStaleResources() throws {
        let broker = broker(), resource = broker.resources[0]
        let report = try broker.inspectLocally(resource)
        XCTAssertTrue(report.facts.contains { $0.name == "Folder named in title" && $0.source.contains("not verified") })
        XCTAssertFalse(report.facts.contains { $0.name == "Working directory" })
        try broker.assign(resource.id, project: nil, safety: .blocked)
        XCTAssertThrowsError(try broker.inspectLocally(resource))
        XCTAssertThrowsError(try broker.inspectLocally(broker.resources[0]))
    }
    func testBrowserInspectionRemovesCredentialsAndQuerySecrets() {
        var e = entry("Conversation")
        e.browserTab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: 2, title: "Conversation", url: "https://user:password@chatgpt.com/c/abc?token=SECRET#PRIVATE", minimized: false, windowTitle: "Conversation", index: 1)
        let resource = ManagedResource(id: UUID(), revision: UUID(), adapter: "Chrome", title: "Conversation", kind: "Tab", capabilities: [.open])
        let report = ResourceInspector.inspect(resource, entry: e)
        XCTAssertEqual(report.facts.first { $0.name == "Page address" }?.value, "https://chatgpt.com/c/abc")
        XCTAssertTrue(report.limitations.contains { $0.contains("have not been read") })
    }
    func testConductorLookupBindsBothIDsAndNeverCreatesMissingDatabase() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let repo = UUID().uuidString.lowercased(), workspace = UUID().uuidString.lowercased()
        let route = "tauri://localhost/repository/\(repo)/workspace/\(workspace)"
        XCTAssertNil(ConductorMetadata.directory(route: route, database: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE workspaces (id TEXT, repository_id TEXT, workspace_path TEXT, state TEXT); INSERT INTO workspaces VALUES ('\(workspace)', '\(repo)', '/tmp/atlas', 'ready');", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(ConductorMetadata.directory(route: route, database: file), "/tmp/atlas")
        XCTAssertNil(ConductorMetadata.directory(route: route.replacingOccurrences(of: repo, with: UUID().uuidString), database: file))
        XCTAssertEqual(sqlite3_exec(db, "UPDATE workspaces SET state='archived'", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(ConductorMetadata.directory(route: route, database: file))
    }
    func testReadOnlyQuestionCanInspectDiscoveryOnlyConversation() async throws {
        let broker = broker()
        var conversation = entry("Maya")
        conversation.conversation = ConversationDestination(appID: Conversations.messagesID, name: "Maya", scope: "")
        broker.reconcile([conversation])
        XCTAssertTrue(broker.resources[0].capabilities.isEmpty)
        var tools = ResourceTools(broker: broker)
        tools.planner = { _, resources, _, _, _ in OpenProposal(message: "Inspect", candidates: [resources[0].id], intent: "inspect") }
        let result = try await tools.search("What is this conversation?", endpoint: "test")
        XCTAssertEqual(result.intent, .inspect)
        XCTAssertEqual(try tools.inspect(result.resources[0]).facts.first { $0.name == "Destination" }?.value, "Maya")
        XCTAssertThrowsError(try OpenProposal(message: "Open", candidates: [result.resources[0].id]).resolve(in: result.resources))
    }
}

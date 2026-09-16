import XCTest
import ApplicationServices
@testable import TerminalVelocity

@MainActor final class IntentToolTests: XCTestCase {
    struct Adapter: DeliveryAdapter {
        let descriptor: DeliveryCapability
        var find: (String) async throws -> [DeliveryRecipient]
        var deliver: (LinkDeliveryPreview) async throws -> Bool
        func recipients(matching query: String) async throws -> [DeliveryRecipient] { try await find(query) }
        func send(_ preview: LinkDeliveryPreview) async throws -> Bool { try await deliver(preview) }
    }
    func person(_ adapter: String, name: String = "Graham") -> DeliveryRecipient {
        DeliveryRecipient(id: "person", name: name, handle: "person", accountID: "team", adapterID: adapter, adapterName: adapter)
    }
    func entry(_ url: String = "https://example.com/video") -> WindowEntry {
        let tab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: 2, title: "Video", url: url, minimized: false, windowTitle: "Video", index: 1)
        return WindowEntry(id: "video", pid: 900001, appName: "Chrome", title: "Video", icon: nil,
                           element: AXUIElementCreateApplication(900001), minimized: false, hidden: false, terminal: false, browserTab: tab)
    }
    func broker() -> ResourceBroker {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in true }
        broker.reconcile([entry()]); return broker
    }
    func testSearchProducesTypedMatchesAndRejectsInventedActions() async throws {
        let broker = broker()
        var tools = ResourceTools(broker: broker)
        tools.planner = { text, resources, shareable, _, _ in
            XCTAssertEqual(text, "send the video")
            XCTAssertEqual(shareable, Set(resources.map(\.id)))
            return OpenProposal(message: "Review", candidates: [resources[0].id], intent: "shareLink", recipient: "Graham")
        }
        let result = try await tools.search("send the video", endpoint: "test")
        XCTAssertEqual(result.intent, .shareLink)
        XCTAssertEqual(result.links[result.resources[0].id]?.url, "https://example.com/video")
        tools.planner = { _, resources, _, _, _ in OpenProposal(message: "Oops", candidates: [resources[0].id], intent: "shell") }
        do { _ = try await tools.search("run", endpoint: "test"); XCTFail() } catch {}
        broker.reconcile([entry("https://example.com/changed")])
        XCTAssertThrowsError(try tools.getLink(result.resources[0]))
    }
    func testRecipientSearchKeepsCrossAppAmbiguityAndReportsPartialFailure() async throws {
        let a = person("a"), b = person("b")
        let registry = DeliveryAdapters(adapters: [
            Adapter(descriptor: .init(id: "a", name: "A", capability: "shareLink"), find: { _ in [a] }, deliver: { _ in XCTFail(); return false }),
            Adapter(descriptor: .init(id: "b", name: "B", capability: "shareLink"), find: { _ in [b] }, deliver: { _ in XCTFail(); return false }),
            Adapter(descriptor: .init(id: "c", name: "C", capability: "shareLink"), find: { _ in throw AccessError.unavailable }, deliver: { _ in XCTFail(); return false })
        ])
        let tools = RecipientTools(adapters: registry)
        let result = try await tools.search("Graham")
        XCTAssertEqual(result.matches, [a, b])
        XCTAssertNotEqual(a.selectionKey, b.selectionKey)
        XCTAssertEqual(result.issues.map(\.adapterID), ["c"])
        do { _ = try await tools.search("Graham", adapterID: "c"); XCTFail("Explicit provider must not fall back") } catch {}
        do { _ = try await tools.search("Graham", adapterID: "unknown"); XCTFail() } catch {}
    }
    func testCancelledRecipientLookupDoesNotContinueToAnotherAdapter() async throws {
        let recipient = person("a")
        let registry = DeliveryAdapters(adapters: [
            Adapter(descriptor: .init(id: "a", name: "A", capability: "shareLink"), find: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return [recipient]
            }, deliver: { _ in XCTFail(); return false }),
            Adapter(descriptor: .init(id: "b", name: "B", capability: "shareLink"), find: { _ in XCTFail("Cancelled discovery continued"); return [] }, deliver: { _ in XCTFail(); return false })
        ])
        let task = Task { try await RecipientTools(adapters: registry).search("Graham") }
        do { _ = try await task.value; XCTFail("Cancelled matches returned") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPreparedMessageBindsApprovalToExactAdapterRecipientAndLinkAndIsOneShot() async throws {
        let broker = broker()
        let original = person("a")
        var selectedRecipient = original
        var sent: [LinkDeliveryPreview] = []
        let registry = DeliveryAdapters(adapters: [Adapter(descriptor: .init(id: "a", name: "A", capability: "shareLink"), find: { _ in [original] }, deliver: { sent.append($0); return true })])
        let actions = ActionTools(broker: broker, adapters: registry, verifySource: { _ in true })
        let link = try ResourceTools(broker: broker).getLink(broker.resources[0])
        let action = try actions.prepareMessage(link, to: selectedRecipient, created: Date())
        let success = try await actions.execute(action) { reviewed in
            XCTAssertTrue(reviewed.approvalReason.contains("Graham"))
            XCTAssertEqual(reviewed.recipient, original)
            XCTAssertEqual(reviewed.message, link.url)
            XCTAssertEqual(reviewed.resource, link.source)
            selectedRecipient = self.person("other", name: "Someone else")
            return true
        }
        XCTAssertTrue(success)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].recipient, original)
        XCTAssertEqual(sent[0].body, link.url)
        do { _ = try await actions.execute(action) { _ in XCTFail("No replay approval"); return true }; XCTFail() } catch {}
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(broker.grants.isEmpty)
    }
    func testPreparationAndExecutionRejectChangedSourcesAndDeniedApproval() async throws {
        let broker = broker()
        let recipient = person("a")
        let registry = DeliveryAdapters(adapters: [Adapter(descriptor: .init(id: "a", name: "A", capability: "shareLink"), find: { _ in [recipient] }, deliver: { _ in XCTFail("Must not send"); return true })])
        let actions = ActionTools(broker: broker, adapters: registry, verifySource: { _ in true })
        let link = try ResourceTools(broker: broker).getLink(broker.resources[0])
        let denied = try actions.prepareMessage(link, to: recipient, created: Date())
        do { _ = try await actions.execute(denied) { _ in false }; XCTFail() } catch {}
        let changed = try actions.prepareMessage(link, to: recipient, created: Date())
        do {
            _ = try await actions.execute(changed) { _ in broker.reconcile([self.entry("https://example.com/new")]); return true }
            XCTFail()
        } catch {}
        XCTAssertThrowsError(try actions.prepareMessage(link, to: recipient, created: Date()))
        XCTAssertThrowsError(try actions.prepareOpen(link.source, created: Date()))
    }
}

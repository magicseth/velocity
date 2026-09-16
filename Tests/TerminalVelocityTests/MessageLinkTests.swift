import XCTest
import AppKit
import ApplicationServices
@testable import TerminalVelocity

@MainActor final class MessageLinkTests: XCTestCase {
    let recipient = DeliveryRecipient(id: "account:+15555550100", name: "Test Person", handle: "+15555550100", accountID: "account", adapterID: "com.apple.MobileSMS", adapterName: "Messages")
    func entry(url: String = "https://www.youtube.com/watch?v=test") -> WindowEntry {
        let tab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: 2, title: "Video", url: url, minimized: false, windowTitle: "Video", index: 1)
        return WindowEntry(id: "video", pid: 900001, appName: "Chrome", title: "Video", icon: nil,
                    element: AXUIElementCreateApplication(900001), minimized: false, hidden: false, terminal: false, browserTab: tab)
    }
    func preview(_ broker: ResourceBroker) -> LinkDeliveryPreview {
        LinkDeliveryPreview(id: UUID(), resource: broker.resources[0], url: broker.localLink(broker.resources[0].id)!, recipient: recipient, created: Date())
    }
    func testExactLinkSendIsOneShotAndNeedsBiometrics() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail(); return false }
        broker.reconcile([entry()])
        let denied = preview(broker)
        do { _ = try await broker.sendLinkLocally(denied, authenticate: { false }, verifySource: { _ in XCTFail(); return true }, send: { _ in XCTFail(); return true }); XCTFail() } catch {}
        let approved = preview(broker)
        var sent = 0
        let accepted = try await broker.sendLinkLocally(approved, authenticate: { true }, verifySource: { _ in true }, send: { p in
            XCTAssertEqual(p.recipient, self.recipient)
            XCTAssertEqual(p.body, "https://www.youtube.com/watch?v=test")
            sent += 1; return true
        })
        XCTAssertTrue(accepted)
        do { _ = try await broker.sendLinkLocally(approved, authenticate: { XCTFail(); return true }, verifySource: { _ in true }, send: { _ in XCTFail(); return true }); XCTFail() } catch {}
        XCTAssertEqual(sent, 1)
        XCTAssertTrue(broker.grants.isEmpty)
    }
    func testNavigationAndLiveVerificationFailurePreventSending() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in false }
        broker.reconcile([entry()])
        do {
            _ = try await broker.sendLinkLocally(preview(broker), authenticate: { broker.reconcile([self.entry(url: "https://example.com/new")]); return true }, verifySource: { _ in true }, send: { _ in XCTFail(); return true }); XCTFail()
        } catch {}
        do {
            _ = try await broker.sendLinkLocally(preview(broker), authenticate: { true }, verifySource: { _ in false }, send: { _ in XCTFail(); return true }); XCTFail()
        } catch {}
    }
    func testUnconfirmedSendCannotBeRetriedWithSameApproval() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in false }
        broker.reconcile([entry()])
        let p = preview(broker)
        do { _ = try await broker.sendLinkLocally(p, authenticate: { true }, verifySource: { _ in true }, send: { _ in throw AccessError.unavailable }); XCTFail() } catch {}
        do { _ = try await broker.sendLinkLocally(p, authenticate: { XCTFail(); return true }, verifySource: { _ in true }, send: { _ in XCTFail(); return true }); XCTFail() } catch {}
        XCTAssertTrue(broker.audit.contains { $0.event == "local.sendLink.unconfirmed" })
    }
    func testScriptsCompileWithoutSendingAndGuardStableRecipient() throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in false }
        broker.reconcile([entry()])
        let p = preview(broker)
        let source = MessageLinks.sendSource(p)
        XCTAssertTrue(source.contains("account:+15555550100"))
        XCTAssertTrue(source.contains("handle of p is not"))
        XCTAssertTrue(source.contains("id of account of p is not"))
        for source in [source, MessageLinks.lookupSource("Kyle"), MessageLinks.lookupSource("A\"\\B")] {
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
        }
        XCTAssertFalse(MessageLinks.validURL("javascript:alert(1)"))
        XCTAssertFalse(MessageLinks.validURL("https://user:password@example.com"))
        XCTAssertFalse(MessageLinks.validURL("https://example.com\nother"))
    }
}

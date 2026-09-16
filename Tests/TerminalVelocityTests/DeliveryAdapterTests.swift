import XCTest
@testable import TerminalVelocity

@MainActor final class DeliveryAdapterTests: XCTestCase {
    struct FakeAdapter: DeliveryAdapter {
        let descriptor = DeliveryCapability(id: "test.adapter", name: "Test", capability: "shareLink")
        func recipients(matching query: String) async throws -> [DeliveryRecipient] { [] }
        func send(_ preview: LinkDeliveryPreview) async throws -> Bool { false }
    }
    func testRegistryOnlyResolvesInstalledAdapters() throws {
        let registry = DeliveryAdapters(adapters: [FakeAdapter()])
        XCTAssertEqual(registry.capabilities.map(\.id), ["test.adapter"])
        XCTAssertEqual(try registry.adapter("test.adapter").descriptor.name, "Test")
        XCTAssertThrowsError(try registry.adapter("com.apple.MobileSMS"))
        XCTAssertThrowsError(try registry.adapter("arbitrary.shell"))
    }
    func testSlackRecipientNamesPreferPeopleOverSubstringChannelsAndGroups() {
        XCTAssertEqual(SlackDeliveryAdapter.preferredNames(["cx-graham-test", "Graham Abbott", "Graham Abbott, James"], query: "graham"), ["Graham Abbott"])
        XCTAssertEqual(SlackDeliveryAdapter.preferredNames(["Graham Abbott", "Graham Jones"], query: "graham"), ["Graham Abbott", "Graham Jones"])
        XCTAssertEqual(SlackDeliveryAdapter.preferredNames(["devx", "devx-buzz"], query: "devx"), ["devx"])
    }
    func testSlackRoutesMustBindWorkspaceAndConversation() {
        XCTAssertEqual(SlackRoute.parse("app.slack.com/client/T123/D456")?.key, "T123/D456")
        XCTAssertNotEqual(SlackRoute.parse("app.slack.com/client/T123/D456"), SlackRoute.parse("app.slack.com/client/T999/D456"))
        XCTAssertNil(SlackRoute.parse("https://evil.example/client/T123/D456"))
        XCTAssertNil(SlackRoute.parse("app.slack.com/client/T123"))
        XCTAssertNil(SlackRoute.parse("app.slack.com/client/T123/D456/thread"))
    }
}

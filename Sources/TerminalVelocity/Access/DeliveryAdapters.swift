import Foundation

struct DeliveryCapability: Codable, Equatable {
    let id: String
    let name: String
    let capability: String
}
/// Built-in adapters supply discovery and a narrowly typed executor. They never
/// own approval, biometric authentication, grants, replay protection, or auditing.
@MainActor protocol DeliveryAdapter {
    var descriptor: DeliveryCapability { get }
    func recipients(matching query: String) async throws -> [DeliveryRecipient]
    func send(_ preview: LinkDeliveryPreview) async throws -> Bool
}
@MainActor struct MessagesDeliveryAdapter: DeliveryAdapter {
    let descriptor = DeliveryCapability(id: "com.apple.MobileSMS", name: "Messages / iMessage", capability: "shareLink")
    func recipients(matching query: String) async throws -> [DeliveryRecipient] { try MessageLinks.recipients(matching: query) }
    func send(_ preview: LinkDeliveryPreview) async throws -> Bool { try MessageLinks.send(preview) }
}
@MainActor final class DeliveryAdapters {
    static let shared = DeliveryAdapters(adapters: [MessagesDeliveryAdapter(), SlackDeliveryAdapter()])
    private let adapters: [String: any DeliveryAdapter]
    init(adapters: [any DeliveryAdapter]) {
        precondition(Set(adapters.map { $0.descriptor.id }).count == adapters.count)
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.descriptor.id, $0) })
    }
    var capabilities: [DeliveryCapability] { adapters.values.map(\.descriptor).sorted { $0.id < $1.id } }
    func adapter(_ id: String) throws -> any DeliveryAdapter {
        guard let adapter = adapters[id] else { throw AIGrouping.Failure("No sending adapter is connected for \(id). Nothing was sent. Choose an available app or connect its adapter.") }
        return adapter
    }
    func recipients(adapterID: String, matching query: String) async throws -> [DeliveryRecipient] {
        let recipients = try await adapter(adapterID).recipients(matching: query)
        guard recipients.count <= 40, Set(recipients.map(\.id)).count == recipients.count,
              recipients.allSatisfy({ $0.adapterID == adapterID && !$0.id.isEmpty && !$0.accountID.isEmpty && !$0.handle.isEmpty }) else { throw AccessError.unsupported }
        return recipients
    }
    func send(_ preview: LinkDeliveryPreview) async throws -> Bool {
        try await adapter(preview.recipient.adapterID).send(preview)
    }
}

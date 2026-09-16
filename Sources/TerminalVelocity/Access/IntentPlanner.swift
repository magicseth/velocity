import Foundation

struct OpenProposal: Decodable {
    let message: String
    let candidates: [UUID]
    var intent: String = "open"
    var recipient: String? = nil
    var adapterID: String? = nil
    func resolve(in snapshot: [ManagedResource]) throws -> [ManagedResource] {
        guard message.count <= 500, candidates.count <= 8, Set(candidates).count == candidates.count else { throw AccessError.unsupported }
        return try candidates.map { id in
            guard let resource = snapshot.first(where: { $0.id == id }), resource.safety != .blocked,
                  (intent != "open" || resource.capabilities.contains(.open)) else { throw AccessError.unavailable }
            return resource
        }
    }
}

enum TextRequestPlanner {
    @MainActor static func plan(_ text: String, resources: [ManagedResource], shareable: Set<UUID>, playing: Set<UUID>, endpoint: String) async throws -> OpenProposal {
        guard Features.experimentalAgents else { throw AccessError.unsupported }
        let base = try AIGrouping.endpointURL(endpoint)
        let token = try AIGrouping.token()
        guard token.count >= 32 else { throw AIGrouping.Failure("Configure the AI Gateway connection in AI groups first.") }
        struct Candidate: Encodable { let id: UUID; let app: String; let title: String; let kind: String; let canShare: Bool; let playing: Bool }
        struct Input: Encodable { let text: String; let resources: [Candidate]; let adapters: [DeliveryCapability] }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000,
              !resources.isEmpty, resources.count <= 20000 else { throw AIGrouping.Failure("Enter a request of up to 2,000 characters and wait for windows to finish loading.") }
        var request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("plan-request"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Input(text: text, resources: resources.map {
            Candidate(id: $0.id, app: String($0.adapter.prefix(100)), title: AIGrouping.metadata($0.title, limit: 400), kind: AIGrouping.metadata($0.kind, limit: 400), canShare: shareable.contains($0.id), playing: playing.contains($0.id))
        }, adapters: DeliveryAdapters.shared.capabilities))
        guard request.httpBody!.count <= 2_000_000 else { throw AIGrouping.Failure("The catalog is too large to send in one request.") }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 20000 else { throw AccessError.unsupported }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Check the AI Gateway connection and try again."
            throw AIGrouping.Failure(String(detail.prefix(500)))
        }
        return try JSONDecoder().decode(OpenProposal.self, from: data)
    }
}

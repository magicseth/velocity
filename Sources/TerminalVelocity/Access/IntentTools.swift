import Foundation

// Local typed operations. These are not new external API capabilities.
enum RequestIntent: String { case open, inspect, shareLink, unsupported }
struct ResourceLink {
    let source: ManagedResource
    let url: String
}
struct ResourceSearchResult {
    let intent: RequestIntent
    let message: String
    let resources: [ManagedResource]
    let links: [UUID: ResourceLink]
    let recipientQuery: String?
    let adapterID: String?
    let created: Date
}

@MainActor struct ResourceTools {
    let broker: ResourceBroker
    typealias Planner = @MainActor (String, [ManagedResource], Set<UUID>, Set<UUID>, String) async throws -> OpenProposal
    var planner: Planner = { try await TextRequestPlanner.plan($0, resources: $1, shareable: $2, playing: $3, endpoint: $4) }

    func inspect(_ resource: ManagedResource) throws -> ResourceInspection { try broker.inspectLocally(resource) }
    func getLink(_ resource: ManagedResource) throws -> ResourceLink {
        guard broker.resources.contains(resource), resource.safety != .blocked,
              let url = broker.localLink(resource.id) else { throw AccessError.stale }
        return ResourceLink(source: resource, url: url)
    }
    func search(_ text: String, endpoint: String) async throws -> ResourceSearchResult {
        let created = Date()
        let snapshot = broker.resources.filter { $0.safety != .blocked }
        let links = Dictionary(uniqueKeysWithValues: snapshot.compactMap { resource in
            (try? getLink(resource)).map { (resource.id, $0) }
        })
        let playing = Set(snapshot.filter { broker.localPlaying($0.id) }.map(\.id))
        let proposal = try await planner(text, snapshot, Set(links.keys), playing, endpoint)
        try Task.checkCancellation()
        guard let intent = RequestIntent(rawValue: proposal.intent) else { throw AccessError.unsupported }
        let resources = try proposal.resolve(in: snapshot)
        if intent == .shareLink {
            guard let query = proposal.recipient, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  resources.allSatisfy({ links[$0.id] != nil }) else { throw AccessError.unsupported }
        }
        let ids = Set(resources.map(\.id))
        return ResourceSearchResult(intent: intent, message: proposal.message,
                                    resources: intent == .unsupported ? [] : resources,
                                    links: links.filter { ids.contains($0.key) }, recipientQuery: proposal.recipient,
                                    adapterID: proposal.adapterID, created: created)
    }
}

struct RecipientLookupIssue {
    let adapterID: String
    let message: String
}
struct RecipientSearchResult {
    let matches: [DeliveryRecipient]
    let issues: [RecipientLookupIssue]
}
@MainActor struct RecipientTools {
    let adapters: DeliveryAdapters
    func search(_ query: String, adapterID: String? = nil,
                progress: (DeliveryCapability) -> Void = { _ in }) async throws -> RecipientSearchResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 500 else { throw AccessError.unsupported }
        let ids = adapterID.map { [$0] } ?? adapters.capabilities.map(\.id)
        var matches: [DeliveryRecipient] = []
        var issues: [RecipientLookupIssue] = []
        for id in ids {
            try Task.checkCancellation()
            do {
                let adapter = try adapters.adapter(id)
                progress(adapter.descriptor)
                let found = try await adapters.recipients(adapterID: id, matching: query)
                try Task.checkCancellation()
                matches += found
            } catch {
                try Task.checkCancellation()
                if adapterID != nil { throw error }
                issues.append(RecipientLookupIssue(adapterID: id, message: error.localizedDescription))
            }
        }
        return RecipientSearchResult(matches: matches, issues: issues)
    }
}

/// Construction is confined to preparation tools; approval receives this exact
/// immutable value. No model output can supply an approval or executable script.
struct PreparedLocalAction {
    fileprivate enum Operation {
        case open(ManagedResource, Date)
        case sendLink(LinkDeliveryPreview)
    }
    fileprivate let operation: Operation
    var resource: ManagedResource {
        switch operation {
        case .open(let resource, _): return resource
        case .sendLink(let preview): return preview.resource
        }
    }
    var recipient: DeliveryRecipient? {
        if case .sendLink(let preview) = operation { return preview.recipient }
        return nil
    }
    var message: String? {
        if case .sendLink(let preview) = operation { return preview.body }
        return nil
    }
    var approvalReason: String {
        switch operation {
        case .open(let resource, _): return "Open \(String(resource.title.prefix(120))) in \(resource.adapter)"
        case .sendLink(let preview): return "Send the reviewed link to \(preview.recipient.name) (\(preview.recipient.handle)) via \(preview.recipient.adapterName)"
        }
    }
}
@MainActor struct ActionTools {
    let broker: ResourceBroker
    let adapters: DeliveryAdapters
    var verifySource: (WindowEntry) -> Bool = MessageLinks.sourceIsCurrent
    func prepareOpen(_ resource: ManagedResource, created: Date) throws -> PreparedLocalAction {
        guard broker.resources.contains(resource), resource.safety != .blocked,
              resource.capabilities.contains(.open) else { throw AccessError.stale }
        return PreparedLocalAction(operation: .open(resource, created))
    }
    func prepareMessage(_ link: ResourceLink, to recipient: DeliveryRecipient, created: Date) throws -> PreparedLocalAction {
        guard broker.resources.contains(link.source), broker.localLink(link.source.id) == link.url,
              MessageLinks.validURL(link.url), !recipient.id.isEmpty, !recipient.accountID.isEmpty,
              !recipient.handle.isEmpty else { throw AccessError.stale }
        _ = try adapters.adapter(recipient.adapterID)
        return PreparedLocalAction(operation: .sendLink(LinkDeliveryPreview(id: UUID(), resource: link.source,
            url: link.url, recipient: recipient, created: created)))
    }
    func execute(_ action: PreparedLocalAction,
                 approve: (PreparedLocalAction) async throws -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        // The broker checks freshness before approval and again afterward. Keep
        // approval inside that boundary rather than issuing a reusable Boolean.
        let authenticate = {
            try Task.checkCancellation()
            let approved = try await approve(action)
            try Task.checkCancellation()
            return approved
        }
        switch action.operation {
        case .open(let resource, let created):
            return try await broker.openLocally(resource, proposedAt: created, authenticate: authenticate)
        case .sendLink(let preview):
            return try await broker.sendLinkLocally(preview, authenticate: authenticate, verifySource: verifySource,
                                                   send: { try await adapters.send($0) })
        }
    }
}

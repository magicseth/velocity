import AppKit
import Combine

/// All external authority terminates here. Transport never receives AX handles,
/// AppleScript, keystrokes, paths to execute, or an adapter dispatch primitive.
@MainActor final class ResourceBroker: ObservableObject {
    @Published private(set) var resources: [ManagedResource] = []
    @Published private(set) var agents: [AgentIdentity] = []
    @Published private(set) var projects: [ResourceProject] = []
    @Published private(set) var requests: [ActionRequest] = [] { didSet { pendingChanged?() } }
    @Published private(set) var grants: [ResourceGrant] = []
    @Published private(set) var audit: [AccessAudit] = []
    @Published private(set) var issue: String?
    @Published var endpoint: String?
    var pendingChanged: (() -> Void)?
    private var entries: [UUID: WindowEntry] = [:]
    private var liveIDs: [String: UUID] = [:]
    private var fingerprints: [UUID: String] = [:]
    private var processEpochs: [UUID: String] = [:]
    private let processIdentity: (pid_t) -> String
    private var revokedSessionAgents: Set<UUID> = []
    private var inFlight: Set<UUID> = []
    private let storage: AccessStorage?
    private let clock: () -> Date
    private let writeAudit: (AccessAudit) throws -> Void
    private let executor: (WindowEntry, ResourceAction) async -> Bool

    init(storage: AccessStorage?, clock: @escaping () -> Date = Date.init,
         writeAudit: ((AccessAudit) throws -> Void)? = nil,
         processIdentity: @escaping (pid_t) -> String = { NSRunningApplication(processIdentifier: $0)?.launchDate?.timeIntervalSince1970.description ?? "missing" },
         executor: @escaping (WindowEntry, ResourceAction) async -> Bool) {
        self.storage = storage; self.clock = clock; self.executor = executor; self.processIdentity = processIdentity
        self.writeAudit = writeAudit ?? { event in
            guard let storage else { throw AccessError.storage }
            try storage.append(event)
        }
        if let storage {
            do { let config = try storage.load(); agents = config.agents; projects = config.projects }
            catch { issue = AccessError.storage.localizedDescription }
        } else if writeAudit == nil { issue = AccessError.storage.localizedDescription }
    }
    private func log(_ event: String, agent: UUID? = nil, resource: UUID? = nil, request: UUID? = nil) throws {
        guard issue == nil else { throw AccessError.storage }
        let record = AccessAudit(id: UUID(), date: clock(), event: event, agentID: agent, resourceID: resource, requestID: request)
        do { try writeAudit(record) }
        catch { issue = AccessError.storage.localizedDescription; throw AccessError.storage }
        audit = Array((audit + [record]).suffix(500))
    }
    private func save() throws {
        do { try storage?.save(.init(agents: agents, projects: projects)) }
        catch { issue = AccessError.storage.localizedDescription; throw AccessError.storage }
    }
    func addProject(name: String) throws {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !name.isEmpty else { return }
        try log("project.created")
        projects.append(.init(id: UUID(), name: name)); try save()
    }
    /// Called only by native user controls, never exposed over the agent transport.
    func pair(name: String, project: UUID) throws -> String {
        guard projects.contains(where: { $0.id == project }) else { throw AccessError.unavailable }
        let token = try AccessStorage.token()
        let agent = AgentIdentity(id: UUID(), name: String(name.prefix(100)), tokenDigest: AccessStorage.digest(token), projects: [project])
        try log("agent.paired", agent: agent.id)
        agents.append(agent); try save()
        return token
    }
    func authenticate(_ token: String) throws -> UUID {
        guard issue == nil, token.count == 64 else { throw AccessError.unauthorized }
        let digest = AccessStorage.digest(token)
        guard let agent = agents.first(where: { $0.tokenDigest == digest && !$0.revoked && !revokedSessionAgents.contains($0.id) }) else { throw AccessError.unauthorized }
        return agent.id
    }
    func revokeAgent(_ id: UUID) {
        revokedSessionAgents.insert(id)
        if let index = agents.firstIndex(where: { $0.id == id }) { agents[index].revoked = true }
        grants.removeAll { $0.agentID == id }
        for index in requests.indices where requests[index].agentID == id && requests[index].status == .pending { requests[index].status = .denied }
        do { try save(); try log("agent.revoked", agent: id) } catch { issue = error.localizedDescription }
    }
    func suspend() {
        grants.removeAll()
        for index in requests.indices where requests[index].status == .pending { requests[index].status = .denied }
        do { try log("access.stopped") } catch { issue = error.localizedDescription }
    }
    func revokeGrant(_ id: UUID) {
        guard let grant = grants.first(where: { $0.id == id }) else { return }
        grants.removeAll { $0.id == id }
        do { try log("grant.revoked", agent: grant.agentID, resource: grant.resourceID) } catch { issue = error.localizedDescription }
    }
    /// IDs survive refreshes of the same live target. Disappearance retires the ID;
    /// a later lookalike gets a new ID and cannot inherit an old grant or scope.
    func reconcile(_ snapshot: [WindowEntry]) {
        let unique = Dictionary(grouping: snapshot.filter { $0.launchURL == nil && $0.element != nil }, by: \.id).filter { $0.value.count == 1 }
        var next: [ManagedResource] = [], nextEntries: [UUID: WindowEntry] = [:], nextIDs: [String: UUID] = [:]
        for key in unique.keys.sorted() {
            guard let entry = unique[key]?.first else { continue }
            let processEpoch = processIdentity(entry.pid)
            let liveKey = key + ":" + processEpoch
            let id = liveIDs[liveKey] ?? UUID()
            let fingerprint = AccessStorage.digest(entry.memoryKey + "|" + entry.title + "|" + (entry.browserTab?.url ?? ""))
            // Name-only destinations are discoverable, but are not execution targets:
            // a different conversation/project could later reuse the same name.
            let nameOnly = entry.conversation != nil || (entry.chatProject != nil && entry.chatProject?.url == nil)
            let capabilities: Set<ResourceAction> = nameOnly ? [] : entry.canClose ? [.open, .close] : [.open]
            var resource = resources.first { $0.id == id } ?? ManagedResource(id: id, revision: UUID(), adapter: entry.appName,
                                                                                  title: entry.title, kind: entry.subtitle, capabilities: capabilities)
            if fingerprints[id] != fingerprint || resource.capabilities != capabilities {
                resource.revision = UUID(); resource.projectID = nil; resource.safety = .ask
                grants.removeAll { $0.resourceID == id }
            }
            resource.title = entry.title; resource.kind = entry.subtitle; resource.capabilities = capabilities
            fingerprints[id] = fingerprint
            processEpochs[id] = processEpoch
            next.append(resource); nextEntries[id] = entry; nextIDs[liveKey] = id
        }
        resources = next; entries = nextEntries; liveIDs = nextIDs
        fingerprints = fingerprints.filter { entries[$0.key] != nil }
        processEpochs = processEpochs.filter { entries[$0.key] != nil }
        grants.removeAll { entries[$0.resourceID] == nil || $0.expires <= clock() }
        for index in requests.indices where requests[index].status == .pending {
            if requests[index].expires <= clock() || !resources.contains(where: { $0.id == requests[index].resourceID && $0.revision == requests[index].revision }) {
                requests[index].status = .expired
            }
        }
    }
    func assign(_ resourceID: UUID, project: UUID?, safety: ResourceSafety) throws {
        guard let index = resources.firstIndex(where: { $0.id == resourceID }), project == nil || projects.contains(where: { $0.id == project }) else { throw AccessError.unavailable }
        try log("resource.scopeChanged", resource: resourceID)
        resources[index].projectID = project; resources[index].safety = safety; resources[index].revision = UUID()
        grants.removeAll { $0.resourceID == resourceID }
        for index in requests.indices where requests[index].resourceID == resourceID && requests[index].status == .pending { requests[index].status = .expired }
    }
    private func permitted(_ agentID: UUID, _ resourceID: UUID) throws -> ManagedResource {
        guard issue == nil, let agent = agents.first(where: { $0.id == agentID }), !agent.revoked, !revokedSessionAgents.contains(agentID) else { throw AccessError.unauthorized }
        guard let resource = resources.first(where: { $0.id == resourceID }), let project = resource.projectID,
              agent.projects.contains(project), resource.safety != .blocked else { throw AccessError.unavailable }
        return resource
    }
    func list(agent: UUID) throws -> [ManagedResource] {
        guard agents.contains(where: { $0.id == agent && !$0.revoked }), !revokedSessionAgents.contains(agent) else { throw AccessError.unauthorized }
        try log("catalog.read", agent: agent)
        return resources.filter { (try? permitted(agent, $0.id)) != nil }
    }
    func submit(agent: UUID, resource: UUID, revision: UUID, action: ResourceAction, nonce: UUID, reason: String) async throws -> ActionRequest {
        let target = try permitted(agent, resource)
        guard target.revision == revision else { throw AccessError.stale }
        guard target.capabilities.contains(action) else { throw AccessError.unsupported }
        if let prior = requests.first(where: { $0.agentID == agent && $0.nonce == nonce }) {
            guard prior.resourceID == resource, prior.revision == revision, prior.action == action else { throw AccessError.stale }
            return prior
        }
        guard requests.count < 5000, requests.filter({ $0.agentID == agent && $0.status == .pending }).count < 20 else { throw AccessError.limited }
        let request = ActionRequest(id: UUID(), agentID: agent, nonce: nonce, resourceID: resource, revision: revision, action: action,
                                    reason: String(reason.prefix(500)), created: clock(), expires: clock().addingTimeInterval(300))
        try log("action.requested", agent: agent, resource: resource, request: request.id)
        requests.append(request)
        if grants.contains(where: { $0.agentID == agent && $0.resourceID == resource && $0.revision == revision && $0.action == action && $0.expires > clock() }) {
            try await execute(request.id)
        }
        return requests.first { $0.id == request.id }!
    }
    func request(_ id: UUID, agent: UUID) throws -> ActionRequest {
        guard agents.contains(where: { $0.id == agent && !$0.revoked }), !revokedSessionAgents.contains(agent),
              let index = requests.firstIndex(where: { $0.id == id && $0.agentID == agent }) else { throw AccessError.unauthorized }
        if requests[index].status == .pending && requests[index].expires <= clock() { requests[index].status = .expired }
        return requests[index]
    }

    /// Human-only approval. Closing is always one-shot; a grant never broadens to
    /// all resources, a project, another action, or a later resource revision.
    func approve(_ id: UUID, allowOpenForHour: Bool = false) async throws {
        guard let request = requests.first(where: { $0.id == id }), request.status == .pending else { throw AccessError.stale }
        let target = try permitted(request.agentID, request.resourceID)
        guard target.revision == request.revision, request.expires > clock() else { throw AccessError.stale }
        try log("action.approved", agent: request.agentID, resource: request.resourceID, request: id)
        if allowOpenForHour && request.action == .open {
            try log("grant.created.open.hour", agent: request.agentID, resource: request.resourceID, request: id)
            grants.append(.init(id: UUID(), agentID: request.agentID, resourceID: request.resourceID, revision: request.revision,
                                action: .open, expires: clock().addingTimeInterval(3600)))
        }
        try await execute(id)
    }
    func deny(_ id: UUID) throws {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].status == .pending else { return }
        let request = requests[index]
        try log("action.denied", agent: request.agentID, resource: request.resourceID, request: id)
        requests[index].status = .denied
    }
    private func execute(_ id: UUID) async throws {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].status == .pending else { throw AccessError.stale }
        let request = requests[index]
        let target = try permitted(request.agentID, request.resourceID)
        guard target.revision == request.revision, target.capabilities.contains(request.action), request.expires > clock(),
              let entry = entries[target.id], processEpochs[target.id] == processIdentity(entry.pid), !inFlight.contains(target.id) else { throw AccessError.stale }
        try log("action.executing", agent: request.agentID, resource: target.id, request: id)
        requests[index].status = .executing
        inFlight.insert(target.id)
        defer { inFlight.remove(target.id) }
        let success = await executor(entry, request.action)
        requests[index].status = success ? .succeeded : .failed
        try log(success ? "action.succeeded" : "action.failed", agent: request.agentID, resource: target.id, request: id)
    }
}

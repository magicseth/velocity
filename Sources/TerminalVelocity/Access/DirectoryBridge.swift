import Foundation
import Darwin

indirect enum DirectoryJSON: Codable {
    case object([String: DirectoryJSON]), array([DirectoryJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: DirectoryJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([DirectoryJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
}
struct DirectoryRef: Codable { let deviceId: UUID; let resourceId: UUID; let revision: UUID; var kind = "directory" }
struct DirectoryResource: Codable { let ref: DirectoryRef; let title: String; let path: String; let observedAt: Int64; let available: Bool }
struct DirectoryCatalog: Codable { var `protocol` = "velocity/1"; let deviceId: UUID; let epoch: UUID; let scopeId: UUID; let scopeRevision: UUID; let resources: [DirectoryResource] }
struct DirectoryInspection: Codable { var `protocol` = "velocity/1"; let requestId: String; let target: DirectoryRef; let scopeId: UUID; let scopeRevision: UUID; let observedAt: Int64; let fingerprint: String; let evidence: DirectoryJSON; var source = "velocity"; var actualEffects = ["read-metadata", "read-source"] }

@MainActor final class DirectoryBridge {
    struct Seed: Codable { let id: UUID; let path: String; let identity: String }
    struct State: Codable { var deviceId = UUID(); var scopeId = UUID(); var scopeRevision = UUID(); var agentId: UUID; var token: String; var launchPath: String; var seeds: [Seed] }
    let epoch = UUID()
    private(set) var state: State?
    private let broker: ResourceBroker
    private let file: URL
    private let inspect: (String) async throws -> Data
    private var running = 0
    init(broker: ResourceBroker, directory: URL, inspector: @escaping (String) async throws -> Data = DirectoryBridge.runInspector) throws {
        self.broker = broker; self.file = directory.appendingPathComponent("directory-reader-state.json"); self.inspect = inspector
        if FileManager.default.fileExists(atPath: file.path) { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
    }
    static func privateWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".directory-reader-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AccessError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw AccessError.storage }
    }
    func enroll(inventory: URL, launch: URL, allowedHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let home = allowedHome.path + "/"
        guard inventory.path.hasPrefix(home), launch.path.hasPrefix(home),
              launch.deletingLastPathComponent().resolvingSymlinksInPath().path == launch.deletingLastPathComponent().path else { throw AccessError.unauthorized }
        let data = try Data(contentsOf: inventory)
        guard data.count <= 20_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let nodes = object["nodes"] as? [[String: Any]] else { throw AccessError.unsupported }
        let paths = Set(nodes.compactMap { node -> String? in
            guard let kind = node["kind"] as? String, ["project", "workspace", "component"].contains(kind), let path = node["path"] as? String,
                  (try? Self.signature(path)) != nil else { return nil }
            return path
        })
        guard !paths.isEmpty, paths.count <= 2000 else { throw AccessError.limited }
        let old = state
        let credentials = try broker.pairDirectoryReader()
        var next = State(agentId: credentials.id, token: credentials.token, launchPath: launch.path, seeds: try paths.sorted().map { path in Seed(id: old?.seeds.first(where: { $0.path == path })?.id ?? UUID(), path: path, identity: try Self.identity(path)) })
        if let old { next.deviceId = old.deviceId; next.scopeId = old.scopeId }
        try Self.privateWrite(JSONEncoder().encode(next), to: file)
        state = next
        if let old { broker.revokeAgent(old.agentId) }
    }
    func publish(endpoint: String) throws {
        guard let state else { return }
        _ = try authorize(state.agentId)
        let manifest: [String: String] = ["protocol":"velocity/1", "endpoint":endpoint, "token":state.token, "scopeId":state.scopeId.uuidString, "scopeRevision":state.scopeRevision.uuidString, "deviceId":state.deviceId.uuidString, "epoch":epoch.uuidString]
        try Self.privateWrite(JSONEncoder().encode(manifest), to: URL(fileURLWithPath: state.launchPath))
    }
    private func authorize(_ agent: UUID) throws -> State {
        guard let state, state.agentId == agent, try broker.authenticate(state.token) == agent else { throw AccessError.unauthorized }
        return state
    }
    nonisolated static func identity(_ path: String) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return "\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
    }
    private func signature(_ seed: Seed) throws -> String {
        guard try Self.identity(seed.path) == seed.identity else { throw AccessError.stale }
        return try Self.signature(seed.path)
    }
    nonisolated static func signature(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path, url.resolvingSymlinksInPath().path == path else { throw AccessError.stale }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw AccessError.stale }
        var parts = [String(describing: attrs[.systemNumber]), String(describing: attrs[.systemFileNumber])]
        let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        guard children.count <= 10000 else { throw AccessError.limited }
        for name in children + [".git/HEAD", ".git/index"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: path + "/" + name) { parts.append("\(name):\(a[.systemFileNumber] ?? 0):\(a[.size] ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)") }
        }
        return AccessStorage.digest(parts.joined(separator: "|"))
    }
    nonisolated static func revision(_ signature: String) -> UUID {
        let h = Array(signature.prefix(32)); let s = String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32]); return UUID(uuidString: s)!
    }
    func discover(agent: UUID) async throws -> DirectoryCatalog {
        let s = try authorize(agent)
        try broker.auditDirectory("directory.catalog.read", agent: agent)
        let resources = await Task.detached {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return s.seeds.map { seed -> DirectoryResource in
                let identityMatches = (try? Self.identity(seed.path)) == seed.identity
                let sig = identityMatches ? try? Self.signature(seed.path) : nil
                return .init(ref: .init(deviceId: s.deviceId, resourceId: seed.id, revision: Self.revision(sig ?? AccessStorage.digest("unavailable:" + seed.path))), title: URL(fileURLWithPath: seed.path).lastPathComponent, path: seed.path, observedAt: now, available: sig != nil)
            }
        }.value
        guard try authorize(agent).scopeRevision == s.scopeRevision else { throw AccessError.stale }
        return .init(deviceId: s.deviceId, epoch: epoch, scopeId: s.scopeId, scopeRevision: s.scopeRevision, resources: resources)
    }
    func inspection(agent: UUID, scopeRevision: UUID, resource: UUID, revision: UUID, request: UUID) async throws -> DirectoryInspection {
        let s = try authorize(agent)
        guard s.scopeRevision == scopeRevision, let seed = s.seeds.first(where: { $0.id == resource }) else { throw AccessError.stale }
        let before = try signature(seed)
        guard Self.revision(before) == revision else { throw AccessError.stale }
        guard running < 4 else { throw AccessError.limited }
        running += 1; defer { running -= 1 }
        try broker.auditDirectory("directory.inspection.started", agent: agent, resource: resource, request: request)
        let data: Data
        do { data = try await inspect(seed.path) }
        catch { try broker.auditDirectory("directory.inspection.failed", agent: agent, resource: resource, request: request); throw error }
        let current = try authorize(agent)
        guard current.scopeRevision == s.scopeRevision, try signature(seed) == before else { throw AccessError.stale }
        guard data.count <= 30_000, case let .object(object) = try JSONDecoder().decode(DirectoryJSON.self, from: data),
              case let .string(fingerprint) = object["fingerprint"], fingerprint.count == 64, fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }),
              case let .string(evidencePath) = object["directory"], evidencePath == seed.path,
              case let .array(items) = object["items"], !items.isEmpty else { throw AccessError.unsupported }
        try broker.auditDirectory("directory.inspection.completed", agent: agent, resource: resource, request: request)
        return .init(requestId: request.uuidString.lowercased(), target: .init(deviceId: s.deviceId, resourceId: resource, revision: revision), scopeId: s.scopeId, scopeRevision: s.scopeRevision, observedAt: Int64(Date().timeIntervalSince1970 * 1000), fingerprint: fingerprint, evidence: .object(object))
    }
    nonisolated static func runInspector(_ path: String) async throws -> Data {
        guard let script = Bundle.main.url(forResource: "directory-inspector", withExtension: "py") else { throw AccessError.unavailable }
        return try await Task.detached {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, path]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            process.environment = ["PATH":"/usr/bin:/bin", "GIT_OPTIONAL_LOCKS":"0", "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null"]
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 13, execute: deadline)
            defer { deadline.cancel(); try? pipe.fileHandleForReading.close() }
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 30_000 { kill(process.processIdentifier, SIGKILL); throw AccessError.limited }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AccessError.unavailable }
            return data
        }.value
    }
}

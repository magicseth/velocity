import Foundation
import Network

struct AccessMessage: Codable {
    let operation: String
    var resourceID: UUID?
    var revision: UUID?
    var action: ResourceAction?
    var nonce: UUID?
    var reason: String?
    var requestID: UUID?
    var `protocol`: String?
    var scopeRevision: UUID?
}
struct AccessResponse: Codable {
    var resources: [ManagedResource]?
    var request: ActionRequest?
    var error: String?
    var errorClass: String?
    var directoryCatalog: DirectoryCatalog?
    var directoryInspection: DirectoryInspection?
}
/// A small bounded HTTP envelope, not a general-purpose web server. No cookies,
/// browser origins, chunked bodies, pipelining, or unauthenticated discovery.
enum AccessHTTP {
    struct Envelope { let token: String; let body: Data }
    static func parse(_ data: Data, port: UInt16) throws -> Envelope? {
        guard data.count <= 32768 else { throw AccessError.limited }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw AccessError.limited }
            return nil
        }
        guard separator.lowerBound <= 8192,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw AccessError.unauthorized }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /v1/access HTTP/1.1" else { throw AccessError.unsupported }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw AccessError.unauthorized }
            let key = line[..<colon].lowercased()
            guard fields[key] == nil else { throw AccessError.unauthorized }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["origin"] == nil, fields["transfer-encoding"] == nil,
              fields["host"] == "127.0.0.1:\(port)", fields["content-type"] == "application/json",
              let length = fields["content-length"].flatMap(Int.init), length > 0, length <= 24576,
              let authorization = fields["authorization"], authorization.hasPrefix("Bearer ") else { throw AccessError.unauthorized }
        let body = data[separator.upperBound...]
        guard body.count <= length else { throw AccessError.unauthorized }
        guard body.count == length else { return nil }
        return Envelope(token: String(authorization.dropFirst(7)), body: Data(body))
    }
}

@MainActor final class AccessServer {
    private let broker: ResourceBroker
    var directoryBridge: DirectoryBridge?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var generation = UUID()
    init(broker: ResourceBroker) { self.broker = broker }
    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let generation = self.generation
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if case .ready = state, let port = listener?.port { self.broker.endpoint = "http://127.0.0.1:\(port.rawValue)/v1/access"; do { try self.directoryBridge?.publish(endpoint: self.broker.endpoint!) } catch { self.broker.directoryReaderFailed(); self.stop() } }
                if case .failed = state { self.stop() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == generation, self.connections.count < 16 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                self.receive(connection, id: id, data: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(id) }
            }
        }
        listener.start(queue: .main)
    }
    func stop() {
        generation = UUID()
        broker.suspend()
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); broker.endpoint = nil
    }
    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil, let port = self.listener?.port?.rawValue else { return }
                var accumulated = data
                if let content { accumulated.append(content) }
                do {
                    if let envelope = try AccessHTTP.parse(accumulated, port: port) {
                        let response = await self.handle(envelope)
                        self.send(response, connection: connection, id: id)
                    } else if complete || error != nil { self.finish(id) }
                    else { self.receive(connection, id: id, data: accumulated) }
                } catch { self.send(.init(error: "Invalid request."), connection: connection, id: id) }
            }
        }
    }
    func handle(_ envelope: AccessHTTP.Envelope) async -> AccessResponse {
        var directoryOperation = false
        do {
            let agent = try broker.authenticate(envelope.token)
            let message = try JSONDecoder().decode(AccessMessage.self, from: envelope.body)
            directoryOperation = message.operation.hasPrefix("directory.")
            if directoryOperation {
                guard let object = try JSONSerialization.jsonObject(with: envelope.body) as? [String: Any], message.protocol == "velocity/1", let bridge = directoryBridge else { throw AccessError.unsupported }
                let allowed: Set<String> = message.operation == "directory.discover" ? ["operation", "protocol"] : ["operation", "protocol", "scopeRevision", "resourceID", "revision", "requestID"]
                guard Set(object.keys).isSubset(of: allowed) else { throw AccessError.unsupported }
                switch message.operation {
                case "directory.discover": return .init(directoryCatalog: try await bridge.discover(agent: agent))
                case "directory.inspect":
                    guard let scope = message.scopeRevision, let resource = message.resourceID, let revision = message.revision, let request = message.requestID else { throw AccessError.unsupported }
                    return .init(directoryInspection: try await bridge.inspection(agent: agent, scopeRevision: scope, resource: resource, revision: revision, request: request))
                default: throw AccessError.unsupported
                }
            }
            switch message.operation {
            case "resources": return .init(resources: try broker.list(agent: agent))
            case "request":
                guard let resource = message.resourceID, let revision = message.revision,
                      let action = message.action, let nonce = message.nonce else { throw AccessError.unsupported }
                return .init(request: try await broker.submit(agent: agent, resource: resource, revision: revision, action: action,
                                                             nonce: nonce, reason: message.reason ?? ""))
            case "status":
                guard let id = message.requestID else { throw AccessError.unsupported }
                return .init(request: try broker.request(id, agent: agent))
            default: throw AccessError.unsupported
            }
        } catch let error as AccessError { return .init(error: error.localizedDescription, errorClass: directoryOperation ? String(describing: error) : nil) }
        catch { return .init(error: "Invalid request.") }
    }
    private func send(_ response: AccessResponse, connection: NWConnection, id: UUID) {
        guard let body = try? JSONEncoder().encode(response) else { finish(id); return }
        let status = response.error == nil ? "200 OK" : "403 Forbidden"
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
    }
}

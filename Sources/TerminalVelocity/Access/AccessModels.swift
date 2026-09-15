import Foundation

/// These are the only capabilities exported to external clients. New actions must
/// explicitly acquire policy, adapter support, approval UI, and regression tests.
enum ResourceAction: String, Codable, CaseIterable, Sendable { case open, close }
enum ResourceSafety: String, Codable, CaseIterable { case ask, blocked }
struct ResourceProject: Identifiable, Codable, Equatable { let id: UUID; var name: String }
struct AgentIdentity: Identifiable, Codable {
    let id: UUID
    var name: String
    let tokenDigest: String
    var projects: Set<UUID>
    var revoked = false
}
struct ManagedResource: Identifiable, Codable, Equatable {
    let id: UUID
    var revision: UUID
    let adapter: String
    var title: String
    var kind: String
    var projectID: UUID?
    var safety: ResourceSafety = .ask
    var capabilities: Set<ResourceAction>
}
struct ResourceGrant: Identifiable {
    let id: UUID
    let agentID: UUID
    let resourceID: UUID
    let revision: UUID
    let action: ResourceAction
    let expires: Date
}
enum RequestStatus: String, Codable { case pending, executing, succeeded, failed, denied, expired }
struct ActionRequest: Identifiable, Codable {
    let id: UUID
    let agentID: UUID
    let nonce: UUID
    let resourceID: UUID
    let revision: UUID
    let action: ResourceAction
    let reason: String
    let created: Date
    let expires: Date
    var status: RequestStatus = .pending
}
struct AccessAudit: Identifiable, Codable {
    let id: UUID
    let date: Date
    let event: String
    let agentID: UUID?
    let resourceID: UUID?
    let requestID: UUID?
}
enum AccessError: Error, LocalizedError {
    case unauthorized, unavailable, unsupported, stale, limited, storage
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Not authorized."
        case .unavailable: return "Resource unavailable in the permitted scope."
        case .unsupported: return "This capability is not available."
        case .stale: return "The resource changed. Make a new request."
        case .limited: return "Request limit reached."
        case .storage: return "Local audit storage is unavailable. Actions are disabled."
        }
    }
}

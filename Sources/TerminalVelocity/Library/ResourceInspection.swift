import Foundation
import SQLite3

struct ResourceFact: Identifiable, Codable, Equatable {
    let name: String
    let value: String
    let source: String
    var id: String { name }
}
struct ResourceInspection: Identifiable, Codable, Equatable {
    let resource: ManagedResource
    let observed: Date
    let facts: [ResourceFact]
    let limitations: [String]
    var id: UUID { resource.id }
    var summary: String { "\(resource.title) — \(resource.kind)" }
}

/// Reads only workspace identity metadata, by exact workspace AND repository ID.
/// Conductor owns this schema; unsupported versions return no directory rather
/// than falling back to title guesses or reading sessions/messages.
enum ConductorMetadata {
    static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.conductor.app/conductor.db")
    }
    static func directory(route: String, database: URL = database) -> String? {
        guard ConductorWorkspaces.workspaceRoute(route) != nil, let url = URL(string: route) else { return nil }
        let parts = url.path.split(separator: "/")
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        let sql = "SELECT workspace_path FROM workspaces WHERE lower(id) = ? AND lower(repository_id) = ? AND state != 'archived' LIMIT 2"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, String(parts[3]).lowercased(), -1, transient)
        sqlite3_bind_text(statement, 2, String(parts[1]).lowercased(), -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        let path = String(cString: raw)
        guard path.hasPrefix("/"), !path.contains("\0"), sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return path
    }
}

enum ResourceInspector {
    static func inspect(_ resource: ManagedResource, entry: WindowEntry, observed: Date = Date(),
                        workspaceDirectory: (String) -> String? = { ConductorMetadata.directory(route: $0) }) -> ResourceInspection {
        var facts = [ResourceFact(name: "Application", value: entry.appName, source: "Window catalog"),
                     ResourceFact(name: "Title", value: entry.title, source: "Window catalog")]
        var limitations: [String] = []
        if let tab = entry.browserTab {
            // Never expose embedded credentials, query tokens, or fragments in an inspection.
            if var url = URLComponents(string: tab.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
                if let address = url.string { facts.append(.init(name: "Page address", value: address, source: "Browser tab; query and fragment omitted")) }
                if let host = url.host { facts.append(.init(name: "Website", value: host, source: "Browser tab")) }
            }
            if let profile = entry.browserProfile { facts.append(.init(name: "Browser profile", value: profile, source: "Browser window")) }
            limitations.append("Only the open tab’s identity is known. Page contents and conversation messages have not been read.")
        }
        if let path = entry.documentPath { facts.append(.init(name: "Document path", value: path, source: "Accessibility document attribute")) }
        if entry.terminal {
            let prefix = entry.title.components(separatedBy: " — ")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("~/") || prefix.hasPrefix("/") {
                facts.append(.init(name: "Folder named in title", value: (prefix as NSString).expandingTildeInPath, source: "Terminal title hint; not verified as current directory"))
            }
            limitations.append("The current working directory, running command, and terminal contents have not been verified. A title can be stale or customized.")
        }
        if let project = entry.chatProject {
            facts.append(.init(name: project.mode == "Workspace" ? "Workspace" : "Conversation / project", value: project.name, source: "Application sidebar"))
            if project.mode == "Workspace", let route = project.url,
               let directory = workspaceDirectory(route) {
                facts.append(.init(name: "Workspace directory", value: directory, source: "Conductor workspace metadata; exact repository and workspace IDs"))
            } else if project.mode == "Workspace" {
                limitations.append("Conductor did not provide a directory for this workspace. Its database may be unavailable or use an unsupported schema.")
            }
            limitations.append("Conversation and workspace contents have not been read.")
        }
        if let conversation = entry.conversation {
            facts.append(.init(name: "Destination", value: conversation.name, source: "Application sidebar"))
            if !conversation.scope.isEmpty { facts.append(.init(name: "Workspace ID", value: conversation.scope, source: "Application sidebar")) }
            limitations.append("Sidebar identity only. No message history has been read, and a name alone is not a verified recipient ID.")
        }
        return ResourceInspection(resource: resource, observed: observed, facts: facts, limitations: limitations)
    }
}

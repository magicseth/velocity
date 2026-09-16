import Foundation
import Combine

struct LibraryProject: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var sourceFolder: String? = nil
}
struct LibraryConfiguration: Codable {
    var version = 1
    var projects: [LibraryProject] = []
    var assignments: [String: UUID] = [:]
}

/// Organizational membership is deliberately independent of ResourceProject and
/// agent scopes. Only explicit user assignments are persisted, as hashed keys.
@MainActor final class ResourceLibrary: ObservableObject {
    @Published private(set) var configuration = LibraryConfiguration()
    @Published private(set) var issue: String?
    private let file: URL?
    init(file: URL?) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let decoded = try JSONDecoder().decode(LibraryConfiguration.self, from: Data(contentsOf: file))
            try Self.validate(decoded)
            configuration = decoded
        } catch { issue = "Project library could not be loaded. The existing file has been left untouched." }
    }
    static func validate(_ config: LibraryConfiguration) throws {
        guard config.version == 1, config.projects.count <= 1000, config.assignments.count <= 20000,
              Set(config.projects.map(\.id)).count == config.projects.count else { throw AccessError.storage }
        let projects = Dictionary(uniqueKeysWithValues: config.projects.map { ($0.id, $0) })
        for project in config.projects {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, project.name.count <= 100,
                  project.sourceFolder.map({ $0.hasPrefix("/") && $0.count <= 4096 }) ?? true else { throw AccessError.storage }
            var visited: Set<UUID> = [project.id]
            var parent = project.parentID
            while let id = parent {
                guard let ancestor = projects[id], visited.count < 32, visited.insert(id).inserted else { throw AccessError.storage }
                parent = ancestor.parentID
            }
        }
        guard config.assignments.allSatisfy({ $0.key.count == 64 && $0.key.allSatisfy(\.isHexDigit) && projects[$0.value] != nil }) else { throw AccessError.storage }
    }
    private func commit(_ next: LibraryConfiguration) throws {
        guard issue == nil else { throw AccessError.storage }
        try Self.validate(next)
        if let file {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        configuration = next
    }
    @discardableResult func create(name: String, parent: UUID?) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100,
              !configuration.projects.contains(where: { $0.parentID == parent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw AccessError.unsupported }
        let project = LibraryProject(id: UUID(), name: name, parentID: parent)
        var next = configuration; next.projects.append(project); try commit(next); return project.id
    }
    func move(_ id: UUID, under parent: UUID?) throws {
        var next = configuration
        guard let index = next.projects.firstIndex(where: { $0.id == id }) else { throw AccessError.unavailable }
        next.projects[index].parentID = parent
        try commit(next)
    }
    func rename(_ id: UUID, to name: String) throws {
        var next = configuration
        guard let index = next.projects.firstIndex(where: { $0.id == id }) else { throw AccessError.unavailable }
        next.projects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try commit(next)
    }
    func update(_ id: UUID, name: String, parent: UUID?) throws {
        var next = configuration
        guard let index = next.projects.firstIndex(where: { $0.id == id }) else { throw AccessError.unavailable }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.projects.contains(where: { $0.id != id && $0.parentID == parent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw AccessError.unsupported }
        next.projects[index].name = name
        next.projects[index].parentID = parent
        try commit(next)
    }
    func remove(_ id: UUID) throws {
        let ids = descendants(of: id)
        var next = configuration
        next.projects.removeAll { ids.contains($0.id) }
        next.assignments = next.assignments.filter { !ids.contains($0.value) }
        try commit(next)
    }
    func assign(key: String, project: UUID?) throws {
        var next = configuration
        next.assignments[key] = project
        try commit(next)
    }
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var prior = 0
        while prior != result.count {
            prior = result.count
            for project in configuration.projects where project.parentID.map(result.contains) == true { result.insert(project.id) }
        }
        return result
    }
    func path(_ id: UUID) -> String {
        guard let project = configuration.projects.first(where: { $0.id == id }) else { return "Unfiled" }
        return project.parentID.map { path($0) + " / " + project.name } ?? project.name
    }
}

struct LibrarySuggestion: Identifiable {
    let folder: String
    let sources: [String]
    let resources: [ManagedResource]
    var id: String { folder }
    var name: String { (folder as NSString).lastPathComponent }
}

extension ResourceLibrary {
    /// Suggestions never change membership until the native user applies them.
    static func suggestions(broker: ResourceBroker) -> [LibrarySuggestion] {
        var groups: [String: (Set<String>, [ManagedResource])] = [:]
        for resource in broker.resources where resource.safety != .blocked {
            guard let inspection = try? broker.inspectLocally(resource) else { continue }
            let fact = inspection.facts.first { $0.name == "Workspace directory" }
                ?? inspection.facts.first { $0.name == "Folder named in title" }
                ?? inspection.facts.first { $0.name == "Document path" }
            guard let fact else { continue }
            let path = (fact.value as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { continue }
            let folder = fact.name == "Document path" ? (path as NSString).deletingLastPathComponent : path
            guard folder != "/", !folder.isEmpty else { continue }
            var group = groups[folder] ?? ([], [])
            group.0.insert(fact.source); group.1.append(resource); groups[folder] = group
        }
        return groups.map { LibrarySuggestion(folder: $0.key, sources: $0.value.0.sorted(), resources: $0.value.1) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }
    func apply(_ suggestions: [LibrarySuggestion], broker: ResourceBroker) throws {
        var next = configuration
        for suggestion in suggestions {
            let keys = try suggestion.resources.map { resource -> String in
                guard let key = broker.libraryKey(resource), resource.safety != .blocked else { throw AccessError.stale }
                return key
            }
            // The full folder path disambiguates identically named repositories.
            let base = String(suggestion.name.prefix(80))
            let id: UUID
            if let existing = next.projects.first(where: { $0.sourceFolder == suggestion.folder }) { id = existing.id }
            else {
                var name = base, suffix = 2
                while next.projects.contains(where: { $0.parentID == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(base) (\(suffix))"; suffix += 1
                }
                id = UUID(); next.projects.append(.init(id: id, name: name, parentID: nil, sourceFolder: suggestion.folder))
            }
            for key in keys where next.assignments[key] == nil { next.assignments[key] = id }
        }
        try commit(next)
    }
}

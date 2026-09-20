import AppKit
import Foundation

// WHAT THIS MAC HAS OPEN FOR EACH OF JULIA'S PROJECTS.
//
// Seth, 2026-09-19: "mousing over it should pop open a list with various
// things that are related to it, i.e. browser, terminals etc. then i should be
// able to foreground them all at once."
//
// Velocity already knows every window, tab, terminal and chat on the Mac. Julia
// knows his projects. This joins them the way the board joins needs to
// projects — by squash-matching the project's name against what a window says
// about itself (title, document path, tab URL, chat project) — and reports the
// manifest per project. The strip's hover card lists it; "Foreground all" comes
// back as velocity://foreground?project=… and runs the same group focus the
// palette uses for an objective.

struct JuliaWindow: Equatable, Codable {
    let key: String
    let kind: String     // terminal | browser | chat | document | window
    let app: String
    let title: String
}

enum JuliaWorkspace {
    /// Lowercase, no spaces/underscores/hyphens — the board's squash, so both
    /// sides of the wire agree on what "the same name" means.
    static func squash(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
    }
    static func mentions(_ entry: WindowEntry, _ project: String) -> Bool {
        let needle = squash(project)
        guard needle.count >= 3 else { return false }
        var hay = [entry.title, entry.documentPath ?? "", entry.browserTab?.url ?? "",
                   entry.chatProject?.name ?? "", entry.launchURL?.path ?? ""]
        if let path = entry.browserTab?.url, let host = URL(string: path)?.host { hay.append(host) }
        return hay.contains { squash($0).contains(needle) }
    }
    static func kind(_ entry: WindowEntry) -> String {
        if entry.terminal { return "terminal" }
        if entry.browserTab != nil { return "browser" }
        if entry.chatProject != nil || entry.conversation != nil { return "chat" }
        if entry.documentPath != nil { return "document" }
        return "window"
    }
    /// The windows that belong to a project, one per window/tab, terminals first.
    static func windows(for project: String, in entries: [WindowEntry]) -> [JuliaWindow] {
        var seen: Set<String> = []
        var out: [JuliaWindow] = []
        for entry in entries where entry.cachedTerminal == nil && entry.closedTab == nil && entry.launchURL == nil {
            guard mentions(entry, project), seen.insert(entry.id).inserted else { continue }
            out.append(JuliaWindow(key: entry.id, kind: kind(entry), app: entry.appName, title: String(entry.title.prefix(140))))
        }
        let order = ["terminal": 0, "chat": 1, "document": 2, "browser": 3, "window": 4]
        return Array(out.sorted { (order[$0.kind] ?? 9, $0.title) < (order[$1.kind] ?? 9, $1.title) }.prefix(40))
    }
    static func manifest(projects: [String], entries: [WindowEntry]) -> [String: [JuliaWindow]] {
        var out: [String: [JuliaWindow]] = [:]
        for project in projects { out[project] = windows(for: project, in: entries) }
        return out
    }
    /// Which projects the board must hear about: changed lists, and lists that
    /// went empty (so the row is forgotten).
    static func changes(previous: [String: [JuliaWindow]], current: [String: [JuliaWindow]]) -> [String: [JuliaWindow]] {
        var out: [String: [JuliaWindow]] = [:]
        for (project, windows) in current where previous[project] != windows { out[project] = windows }
        for project in previous.keys where current[project] == nil && !(previous[project] ?? []).isEmpty { out[project] = [] }
        return out
    }
    /// The entries a "foreground all" should raise, and which one leads.
    static func group(for project: String, in entries: [WindowEntry]) -> (entries: [WindowEntry], lead: WindowEntry)? {
        let keys = Set(windows(for: project, in: entries).map(\.key))
        let members = entries.filter { keys.contains($0.id) }
        guard let lead = members.first(where: \.terminal) ?? members.first else { return nil }
        return (members, lead)
    }
    static func query(in url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

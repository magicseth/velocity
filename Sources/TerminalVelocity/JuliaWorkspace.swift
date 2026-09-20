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
    /// For a terminal agent: working | idle | needs_input — what its title says right now.
    var state: String? = nil
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
    static func state(_ entry: WindowEntry) -> String? {
        switch entry.attention {
        case .working: return "working"
        case .idle: return "idle"
        case .needsInput: return "needs_input"
        case .none: return nil
        }
    }
    /// A title that reads like a secret never leaves the Mac — a login code in a
    /// mail subject, a password reset, a verification link. Matching is broad on
    /// purpose: missing a window is cheap, shipping a code is not.
    static func looksSensitive(_ title: String) -> Bool {
        let t = title.lowercased()
        let words = ["login code", "verification code", "security code", "one-time", "one time code", "passcode", "password", "2fa", "two-factor", "otp", "reset your", "confirm your email", "sign-in code", "sign in code"]
        if words.contains(where: t.contains) { return true }
        return t.range(of: #"code.*\d{4,8}|\d{4,8}.*code"#, options: .regularExpression) != nil
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
            guard mentions(entry, project), !looksSensitive(entry.title), seen.insert(entry.id).inserted else { continue }
            out.append(JuliaWindow(key: entry.id, kind: kind(entry), app: entry.appName, title: String(entry.title.prefix(140)), state: state(entry)))
        }
        let order = ["terminal": 0, "chat": 1, "document": 2, "browser": 3, "window": 4]
        return Array(out.sorted { (order[$0.kind] ?? 9, $0.title) < (order[$1.kind] ?? 9, $1.title) }.prefix(40))
    }
    /// Per project, what belongs to it by name — plus a "*" bucket of the
    /// terminals, tabs, chats and documents that matched NO project, so Julia
    /// (Jev) can place what a name-match cannot. Plain windows stay local.
    static func manifest(projects: [String], entries: [WindowEntry]) -> [String: [JuliaWindow]] {
        var out: [String: [JuliaWindow]] = [:]
        var matched: Set<String> = []
        for project in projects {
            let list = windows(for: project, in: entries)
            out[project] = list
            for w in list { matched.insert(w.key) }
        }
        var seen: Set<String> = []
        var loose: [JuliaWindow] = []
        for entry in entries where entry.cachedTerminal == nil && entry.closedTab == nil && entry.launchURL == nil {
            guard !matched.contains(entry.id), !looksSensitive(entry.title), seen.insert(entry.id).inserted else { continue }
            let k = kind(entry)
            guard k != "window" else { continue }
            loose.append(JuliaWindow(key: entry.id, kind: k, app: entry.appName, title: String(entry.title.prefix(140)), state: state(entry)))
        }
        out["*"] = Array(loose.prefix(40))
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
    /// The terminal he actually uses: the app behind most of his terminal windows,
    /// else Terminal.app. Bundle ids only; the caller resolves the app.
    static func preferredTerminal(_ entries: [WindowEntry], running: [(pid: pid_t, bundle: String)]) -> String {
        var counts: [String: Int] = [:]
        let byPID = Dictionary(running.map { ($0.pid, $0.bundle) }, uniquingKeysWith: { a, _ in a })
        for entry in entries where entry.terminal {
            if let bundle = byPID[entry.pid] { counts[bundle, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key ?? "com.apple.Terminal"
    }
    /// Only a real directory under his home ever becomes a terminal's cwd.
    static func terminalDirectory(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard url.path.hasPrefix(home + "/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }
    static func query(in url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

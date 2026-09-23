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
    /// For a terminal agent: the task its title names — what is being worked on.
    var task: String? = nil
    /// WHAT THIS WINDOW IS, independent of process and window ids: the folder a
    /// terminal sits in, a tab's site + first path segments, a document's folder, a
    /// chat's project. Julia remembers placements by this — so "that terminal belongs
    /// to ai budget" survives restarts, and a correction made once keeps holding.
    var sig: String? = nil
    /// WHEN IT FIRST APPEARED (ms epoch), by this launch's eyes — so Julia can tell which
    /// tabs an agent opened during its turn ("Opened a new Chrome window with fourteen
    /// tabs…" — which ones?). Absent for whatever was already open when Velocity started:
    /// unknown is not "now".
    var since: Double? = nil
}

/// First-seen per window key, one launch's memory. The first scan is the baseline: what is
/// already open gets no `since`. A key that disappears is forgotten, so a tab closed and
/// reopened is new again.
struct FirstSeen {
    private var at: [String: Double] = [:]
    private var baselined = false
    mutating func stamp(_ manifest: [String: [JuliaWindow]], now: Date = Date()) -> [String: [JuliaWindow]] {
        let ms = now.timeIntervalSince1970 * 1000
        var live: Set<String> = []
        var out = manifest
        for (bucket, windows) in manifest {
            out[bucket] = windows.map { w in
                live.insert(w.key)
                if at[w.key] == nil, baselined { at[w.key] = ms }
                var copy = w; copy.since = at[w.key]; return copy
            }
        }
        if !baselined { baselined = true; for k in live { at[k] = -1 } }   // known, but not when
        at = at.filter { live.contains($0.key) }
        return out.mapValues { $0.map { w in var c = w; if c.since == -1 { c.since = nil }; return c } }
    }
}

enum JuliaWorkspace {
    /// Lowercase, no spaces/underscores/hyphens — the board's squash, so both
    /// sides of the wire agree on what "the same name" means.
    static func squash(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
    }
    /// Does this window name the project by ANY of the names Julia gave for it —
    /// its title, former names, its folder, and the same for its child projects?
    static func mentions(_ entry: WindowEntry, anyOf names: [String]) -> Bool { names.contains { mentions(entry, $0) } }
    static func mentions(_ entry: WindowEntry, _ project: String) -> Bool {
        let needle = squash(project)
        guard needle.count >= 3 else { return false }
        var hay = [entry.title, entry.documentPath ?? "", entry.browserTab?.url ?? "",
                   entry.chatProject?.name ?? "", entry.launchURL?.path ?? ""]
        if let path = entry.browserTab?.url, let host = URL(string: path)?.host { hay.append(host) }
        return hay.contains { squash($0).contains(needle) }
    }
    /// VELOCITY SEES; JULIA JUDGES. This is the only identity work done here: a
    /// stable, content-free-as-possible name for the window. Which project it belongs
    /// to — beyond the cheap name match below — is Julia's call (his corrections
    /// first, then Jev), never decided on this side of the wire.
    static func signature(_ entry: WindowEntry) -> String {
        if let tab = entry.browserTab, let url = URL(string: tab.url), let host = url.host {
            let head = url.path.split(separator: "/").prefix(2).joined(separator: "/")
            return ("tab:" + host + (head.isEmpty ? "" : "/" + head)).lowercased()
        }
        if let project = entry.chatProject { return "chat:" + project.key.lowercased() }
        // A TERMINAL IS ITS FOLDER — checked BEFORE documentPath. A terminal also carries
        // a documentPath, and "the document's parent folder" for ~/Projects/x is
        // ~/Projects: one signature for EVERY terminal he has. A single placement of that
        // signature then dragged mcpfix, waveshare, what2do… all onto one chip.
        if entry.terminal {
            // "user — ~/Projects/x — ✳ task — node ◂ claude — 208×46": the folder is the identity.
            let parts = entry.title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
            if let folder = parts.first(where: { $0.hasPrefix("~") || $0.hasPrefix("/") }) {
                return "term:" + String(folder.prefix(120)).lowercased()
            }
            // No path in the title: the document path IS the folder (not its parent).
            if let path = entry.documentPath, !path.isEmpty {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return "term:" + (path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path).lowercased()
            }
            return "term:" + String((parts.first ?? entry.title).prefix(120)).lowercased()
        }
        if let path = entry.documentPath { return "doc:" + (path as NSString).deletingLastPathComponent.lowercased() }
        return ("win:" + entry.appName + ":" + String(entry.title.prefix(60))).lowercased()
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
        return t.range(of: #"\bcode\b.*\b\d{4,8}\b|\b\d{4,8}\b.*\bcode\b"#, options: .regularExpression) != nil
    }
    static func kind(_ entry: WindowEntry) -> String {
        if entry.terminal { return "terminal" }
        if entry.browserTab != nil { return "browser" }
        if entry.chatProject != nil || entry.conversation != nil { return "chat" }
        if entry.documentPath != nil { return "document" }
        return "window"
    }
    /// The windows that belong to a project, one per window/tab, terminals first.
    static func windows(for project: String, in entries: [WindowEntry]) -> [JuliaWindow] { windows(named: [project], in: entries) }
    static func windows(named names: [String], in entries: [WindowEntry]) -> [JuliaWindow] {
        var seen: Set<String> = []
        var out: [JuliaWindow] = []
        for entry in entries where entry.cachedTerminal == nil && entry.closedTab == nil && entry.launchURL == nil {
            guard mentions(entry, anyOf: names), !looksSensitive(entry.title), seen.insert(entry.id).inserted else { continue }
            out.append(JuliaWindow(key: entry.id, kind: kind(entry), app: entry.appName, title: String(entry.title.prefix(140)), state: state(entry), task: entry.agentTaskTitle.map { String($0.prefix(160)) }, sig: signature(entry)))
        }
        let order = ["terminal": 0, "chat": 1, "document": 2, "browser": 3, "window": 4]
        return Array(out.sorted { (order[$0.kind] ?? 9, $0.title) < (order[$1.kind] ?? 9, $1.title) }.prefix(40))
    }
    /// Per project, what belongs to it by name — plus a "*" bucket of the
    /// terminals, tabs, chats and documents that matched NO project, so Julia
    /// (Jev) can place what a name-match cannot. Plain windows stay local.
    /// WORKING IS LATCHED. An agent's title alternates between the spinner (◐◑) and
    /// the idle mark (✳) every few seconds as it moves between thinking and tool calls;
    /// reported raw, every flip became a manifest change, an agent_started/stopped
    /// event, a pulse starting and stopping on the chip. A terminal stays "working"
    /// until its title has shown idle for `hold` seconds straight. (Needs-input is
    /// never latched: that is a real, sudden change.)
    struct WorkingLatch {
        private var lastWorking: [String: Date] = [:]
        let hold: TimeInterval
        init(hold: TimeInterval = 8) { self.hold = hold }
        mutating func apply(_ windows: [JuliaWindow], now: Date = Date()) -> [JuliaWindow] {
            var out = windows
            for i in out.indices {
                let key = out[i].sig ?? out[i].key
                if out[i].state == "working" { lastWorking[key] = now }
                else if out[i].state != "needs_input", let seen = lastWorking[key], now.timeIntervalSince(seen) < hold { out[i].state = "working" }
                else { lastWorking[key] = nil }
            }
            let live = Set(out.map { $0.sig ?? $0.key })
            lastWorking = lastWorking.filter { live.contains($0.key) || now.timeIntervalSince($0.value) < hold }
            return out
        }
    }

    static func manifest(projects: [String], entries: [WindowEntry]) -> [String: [JuliaWindow]] {
        manifest(names: Dictionary(uniqueKeysWithValues: projects.map { ($0, [$0]) }), order: projects, entries: entries)
    }
    /// `names`: for each of Julia's chips, every name its windows might use (a child
    /// project's terminal is reported under its PARENT's chip). A window goes to the
    /// first chip, in his rank order, that names it.
    static func manifest(names: [String: [String]], order: [String], entries: [WindowEntry]) -> [String: [JuliaWindow]] {
        var out: [String: [JuliaWindow]] = [:]
        var matched: Set<String> = []
        for project in order {
            let list = windows(named: names[project] ?? [project], in: entries).filter { !matched.contains($0.key) }
            out[project] = list
            for w in list { matched.insert(w.key) }
        }
        var seen: Set<String> = []
        var loose: [JuliaWindow] = []
        for entry in entries where entry.cachedTerminal == nil && entry.closedTab == nil && entry.launchURL == nil {
            guard !matched.contains(entry.id), !looksSensitive(entry.title), seen.insert(entry.id).inserted else { continue }
            let k = kind(entry)
            guard k != "window" else { continue }
            loose.append(JuliaWindow(key: entry.id, kind: k, app: entry.appName, title: String(entry.title.prefix(140)), state: state(entry), task: entry.agentTaskTitle.map { String($0.prefix(160)) }, sig: signature(entry)))
        }
        // Terminals first: they are where his agents are. (Forty chat windows once filled
        // the bucket and every unsorted terminal fell off the end.)
        let rank = ["terminal": 0, "document": 1, "browser": 2, "chat": 3]
        out["*"] = Array(loose.sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }.prefix(40))
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
    static func group(for project: String, names: [String]? = nil, in entries: [WindowEntry]) -> (entries: [WindowEntry], lead: WindowEntry)? {
        let keys = Set(windows(named: names ?? [project], in: entries).map(\.key))
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

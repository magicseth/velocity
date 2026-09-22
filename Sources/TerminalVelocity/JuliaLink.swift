import AppKit
import CryptoKit
import Foundation

// Velocity DISCOVERS that an agent on this Mac is waiting on him; Julia's one
// work board OWNS that fact. Each waiting terminal becomes an attentionReports
// row (idempotent per externalId), is resolved when the agent moves on, and
// carries a jump handle so "Jump to it" on the project strip comes back here as
// velocity://focus?handle=… and raises the exact window. Nothing below reads
// terminal text: project + task come from the title, as the notification does.

struct JuliaReport: Equatable, Codable {
    let externalId: String
    let project: String
    let subtask: String
    let jumpHandle: String?
}

struct JuliaReportDiff: Equatable {
    var report: [JuliaReport] = []
    var resolve: [String] = []
}

/// A jump handle is the notification's AttentionDestination, made URL-safe. It
/// survives Velocity restarts and refuses a replaced terminal process, exactly
/// like a notification click.
enum JuliaJumpHandle {
    static func encode(_ destination: AttentionDestination) -> String? {
        guard let data = try? JSONEncoder().encode(destination) else { return nil }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ handle: String) -> AttentionDestination? {
        guard handle.count <= 2048 else { return nil }
        var base64 = handle.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(AttentionDestination.self, from: data)
    }
    /// The board's identity for one waiting agent: the same key the notification
    /// latches on (window + task), hashed so it is opaque and index-friendly.
    static func id(_ key: String) -> String {
        String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}

/// Pure: what the board should hold given what the last scan saw. A row is only
/// resolved after its agent has been gone for `latch` seconds, so a blinking
/// title marker or a brief AX read failure never flaps the board.
struct JuliaReporter: Equatable {
    private(set) var current: [String: JuliaReport] = [:]
    private var lastSeen: [String: Date] = [:]
    let latch: TimeInterval

    init(latch: TimeInterval = 10) { self.latch = latch }

    @MainActor static func reports(_ entries: [WindowEntry], launch: (pid_t) -> Date?) -> [JuliaReport] {
        AttentionNotifications.waiting(entries).map { key, entry in
            let presentation = AttentionPresentation(entry)
            let handle = launch(entry.pid)
                .flatMap { AttentionDestination(entry: entry, launch: $0) }
                .flatMap(JuliaJumpHandle.encode)
            return JuliaReport(externalId: JuliaJumpHandle.id(key), project: presentation.project,
                subtask: presentation.task, jumpHandle: handle)
        }.sorted { $0.externalId < $1.externalId }
    }

    mutating func observe(_ reports: [JuliaReport], now: Date = Date()) -> JuliaReportDiff {
        var diff = JuliaReportDiff()
        let live = Set(reports.map(\.externalId))
        for report in reports {
            lastSeen[report.externalId] = now
            if current[report.externalId] != report { diff.report.append(report); current[report.externalId] = report }
        }
        for id in current.keys.sorted() where !live.contains(id) {
            if now.timeIntervalSince(lastSeen[id] ?? .distantPast) >= latch {
                diff.resolve.append(id); current[id] = nil; lastSeen[id] = nil
            }
        }
        return diff
    }

    /// Restart: whatever this Mac reported before is gone from memory but not
    /// from the board. Forget it here so the next scan resolves what no longer waits.
    mutating func restore(_ reports: [JuliaReport], now: Date) {
        for report in reports where current[report.externalId] == nil {
            current[report.externalId] = report; lastSeen[report.externalId] = now.addingTimeInterval(-latch)
        }
    }
}

/// The phone's shape: a surface token minted by pairing, then the function API.
struct JuliaClient {
    enum Function: String {
        case createCode = "pairing:createCode", status = "pairing:status"
        case report = "attention:report", resolve = "attention:resolve"
        case projects = "attention:byProject", workspace = "attention:workspace"
        case exchange = "exchanges:report"
        var kind: String { self == .status || self == .projects ? "query" : "mutation" }
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static let defaultEndpoint = "https://hidden-kudu-77.convex.cloud"
    let endpoint: URL

    init(endpoint: String = UserDefaults.standard.string(forKey: "juliaEndpoint") ?? JuliaClient.defaultEndpoint) throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host?.hasSuffix(".convex.cloud") == true,
              url.user == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw Failure(message: "Julia’s endpoint must be an HTTPS .convex.cloud deployment URL.")
        }
        self.endpoint = url
    }

    func call(_ function: Function, _ args: [String: Any]) async throws -> Any? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/\(function.kind)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": function.rawValue, "args": args, "format": "json"])
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 200_000, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Julia answered with something that isn’t JSON.")
        }
        if body["status"] as? String == "success" { return body["value"] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = (body["errorMessage"] as? String).map { String($0.prefix(300)) } ?? "HTTP \(status)"
        throw Failure(message: "\(function.rawValue) failed: \(detail)")
    }
}

enum JuliaKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.seth.terminal-velocity.julia", kSecAttrAccount as String: "surface-token"]
    static func token() -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw JuliaClient.Failure(message: "Couldn’t save Julia’s surface token in Keychain (\(status)).") }
    }
    static func forget() { SecItemDelete(query as CFDictionary) }
}

@MainActor final class JuliaLink {
    enum State: Equatable { case unpaired, pairing(code: String), paired }
    private(set) var state: State = .unpaired
    private(set) var token = ""
    var openEntry: ((WindowEntry) -> Void)?
    /// The palette's group focus: raise these, this one on top.
    var foreground: (([WindowEntry], WindowEntry) async -> Bool)?
    /// Everything on the Mac right now (for jump-by-project and foreground).
    var allEntries: (() -> [WindowEntry])?
    private var projectTitles: [String] = []
    /// Every name each chip's windows might use (title, former names, folder, children's).
    private var projectNames: [String: [String]] = [:]
    private var projectsFetchedAt = Date.distantPast
    private var workspace: [String: [JuliaWindow]] = [:]
    private var pendingWorkspace: [String: [JuliaWindow]]?
    /// He asked an agent something; is there an answer? (AnswerWatcher.swift)
    private var answers: AnswerWatcher?
    var notice: ((String) -> Void)?
    var changed: (() -> Void)?
    private var reporter = JuliaReporter()
    private var pairingTask: Task<Void, Never>?
    private var syncing = false
    private var pendingReports: [JuliaReport]?
    private let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Velocity/julia-reports.json")

    init() {
        token = JuliaKeychain.token()
        state = token.isEmpty ? .unpaired : .paired
        if let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode([JuliaReport].self, from: data) {
            reporter.restore(saved, now: Date())
        }
    }

    var menuTitle: String {
        switch state {
        case .unpaired: return "Connect to Julia…"
        case .pairing(let code): return "Julia code \(code) (copied) — enter it in Julia"
        case .paired: return "Disconnect from Julia"
        }
    }

    func toggle() {
        switch state {
        case .unpaired: pair()
        case .pairing: pairingTask?.cancel(); state = .unpaired; changed?()
        case .paired:
            pairingTask?.cancel(); JuliaKeychain.forget(); token = ""; state = .unpaired
            reporter = JuliaReporter(); try? FileManager.default.removeItem(at: store); changed?()
        }
    }

    private func pair() {
        pairingTask?.cancel()
        pairingTask = Task { @MainActor [weak self] in
            do {
                let client = try JuliaClient()
                let created = try await client.call(.createCode, ["proposedName": "Velocity", "kind": "laptop",
                    "capabilities": ["attention"]]) as? [String: Any]
                guard let code = created?["code"] as? String else { throw JuliaClient.Failure(message: "Julia didn’t hand back a pairing code.") }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                self?.state = .pairing(code: code); self?.changed?()
                self?.notice?("Julia pairing code \(code) is on your clipboard — enter it in Julia.")
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await client.call(.status, ["code": code]) as? [String: Any]
                    switch status?["status"] as? String {
                    case "claimed":
                        guard let token = status?["token"] as? String, token.count >= 16 else { throw JuliaClient.Failure(message: "Julia claimed the code without a token.") }
                        try JuliaKeychain.save(token)
                        self?.token = token; self?.state = .paired; self?.changed?()
                        self?.notice?("Connected to Julia. Agents that need you now show on her project strip.")
                        return
                    case "expired", "missing": throw JuliaClient.Failure(message: "The pairing code \(code) expired before it was entered.")
                    default: continue
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.state = .unpaired; self?.changed?()
                self?.notice?("Couldn’t connect to Julia: " + error.localizedDescription)
            }
        }
    }

    /// An exchange changed (asked → working → answered). Velocity adds the one thing only
    /// it knows — a handle back to the exact terminal tab the conversation is in.
    private func report(_ e: Exchange) {
        guard state == .paired, let client = try? JuliaClient() else { return }
        var args: [String: Any] = ["token": token, "externalId": e.externalId, "source": e.source, "sessionId": e.sessionId,
            "project": e.cwd.map { ($0 as NSString).lastPathComponent } ?? e.source, "question": e.question,
            "askedAt": e.askedAt, "done": e.done]
        if let cwd = e.cwd { args["cwd"] = cwd }
        if let answer = e.answer { args["answer"] = answer }
        if let at = e.answeredAt { args["answeredAt"] = at }
        if let cwd = e.cwd, let jump = Self.jumpHandle(forFolder: cwd, in: allEntries?() ?? []) { args["jump"] = jump }
        Task { _ = try? await client.call(.exchange, args) }
    }

    /// RAISE A WINDOW FROM THE BACKGROUND. macOS 14 lets an app hand activation to
    /// another only while it is itself active (cooperative activation), and Velocity is
    /// not active when Julia sends a URL — so WindowCatalog.focus quietly failed whenever
    /// the target was not already frontmost (measured: works with Terminal in front,
    /// nothing with Chrome in front; "clicking open in what2do doesn't bring it to the
    /// forefront"). Velocity is a menu-bar app with nothing to show, so activating it for
    /// a beat is invisible; then it yields to the target and steps back.
    private func raise(_ entry: WindowEntry) {
        Task { @MainActor [weak self] in
            guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid {
                if await !WindowCatalog.focus(entry) { self?.openEntry?(entry) }
                return
            }
            // A background app's own activation requests are ignored on macOS 14 — measured:
            // NSApp.activate() never took, app.activate() reported success while the target
            // stayed behind Chrome, and `open -g` did the same. What IS honoured from the
            // background is a Launch Services open WITH activation — what `open -a` does.
            // So: bring the app forward that way, then raise the exact window and tab.
            guard let url = app.bundleURL else { return }
            app.unhide()
            if let window = entry.element { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                Task { @MainActor in
                    if error != nil { self?.notice?("Couldn’t bring \(app.localizedName ?? "that app") forward."); return }
                    for _ in 0..<20 {
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if let window = entry.element {
                        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    }
                    if entry.tab != nil || entry.browserTab != nil { _ = await WindowCatalog.focus(entry) }
                }
            }
        }
    }

    /// The same tab of the same running process, whatever its title says now.
    static func sameTab(_ d: AttentionDestination, in entries: [WindowEntry]) -> WindowEntry? {
        guard NSRunningApplication(processIdentifier: d.pid)?.launchDate == d.launch else { return nil }
        let tabs = entries.filter { $0.pid == d.pid && $0.id == d.entryID }
        if tabs.count == 1 { return tabs[0] }
        let inWindow = entries.filter { $0.pid == d.pid && $0.windowKey == d.windowKey }
        return inWindow.count == 1 ? inWindow[0] : nil
    }
    /// The terminal for a conversation's folder. Exact first; then the same folder NAME
    /// (a tab titled "convex-app" for ~/Projects/what2do/convex-app — Open did nothing);
    /// then a terminal sitting in a parent or child of that folder. Never a random one.
    static func terminal(inFolder sig: String, in entries: [WindowEntry]) -> WindowEntry? {
        let want = sig.lowercased()
        let terms = entries.filter(\.terminal)
        let pick: ([WindowEntry]) -> WindowEntry? = { $0.first(where: { $0.attention != .none }) ?? $0.first }
        if let e = pick(terms.filter { JuliaWorkspace.signature($0) == want }) { return e }
        let name = String(want.split(separator: "/").last ?? Substring(want.dropFirst(5)))
        guard name.count >= 3 else { return nil }
        if let e = pick(terms.filter { let s = JuliaWorkspace.signature($0); return s == "term:" + name || s.hasSuffix("/" + name) }) { return e }
        return pick(terms.filter { let s = JuliaWorkspace.signature($0); return s.hasPrefix(want + "/") || (want.hasPrefix(s + "/") && s.count > 8) })
    }

    /// The terminal sitting in that folder — preferring one whose title shows an agent.
    static func jumpHandle(forFolder cwd: String, in entries: [WindowEntry]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sig = "term:" + (cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd).lowercased()
        let here = entries.filter { $0.terminal && JuliaWorkspace.signature($0) == sig }
        guard let entry = here.first(where: { $0.attention != .none }) ?? here.first,
              let launch = NSRunningApplication(processIdentifier: entry.pid)?.launchDate,
              let destination = AttentionDestination(entry: entry, launch: launch) else { return nil }
        return JuliaJumpHandle.encode(destination)
    }

    /// Called after every scan: `attention` is what the notifier sees (done
    /// objectives filtered out); `all` is every window, for the per-project manifest.
    func observe(attention entries: [WindowEntry], all: [WindowEntry] = []) {
        guard state == .paired else { return }
        if answers == nil { answers = AnswerWatcher { [weak self] exchange in self?.report(exchange) } }
        let reports = JuliaReporter.reports(entries) { NSRunningApplication(processIdentifier: $0)?.launchDate }
        pendingReports = reports
        if !projectTitles.isEmpty {
            let current = JuliaWorkspace.manifest(names: projectNames, order: projectTitles, entries: all)
            let changed = JuliaWorkspace.changes(previous: workspace, current: current)
            if !changed.isEmpty { pendingWorkspace = (pendingWorkspace ?? [:]).merging(changed) { _, new in new } }
            workspace = current
        }
        if Date().timeIntervalSince(projectsFetchedAt) > 60 { refreshProjects() }
        sync()
    }

    private func refreshProjects() {
        projectsFetchedAt = Date()
        Task { @MainActor [weak self] in
            guard let self, let client = try? JuliaClient() else { return }
            guard let value = try? await client.call(.projects, ["token": token]) as? [String: Any],
                  let projects = value["projects"] as? [[String: Any]] else { return }
            projectTitles = projects.compactMap { $0["title"] as? String }
            var names: [String: [String]] = [:]
            for p in projects { if let t = p["title"] as? String { names[t] = (p["matchNames"] as? [String]) ?? [t] } }
            projectNames = names
        }
    }

    private func sync() {
        guard !syncing, pendingReports != nil || pendingWorkspace != nil else { return }
        let diff = pendingReports.map { reporter.observe($0) } ?? JuliaReportDiff()
        let workspaceChanges = pendingWorkspace ?? [:]
        pendingReports = nil; pendingWorkspace = nil
        persist()
        guard !diff.report.isEmpty || !diff.resolve.isEmpty || !workspaceChanges.isEmpty else { return }
        syncing = true
        Task { @MainActor [weak self] in
            defer { self?.syncing = false; self?.sync() }
            guard let self, let client = try? JuliaClient() else { return }
            do {
                for report in diff.report {
                    var args: [String: Any] = ["token": token, "externalId": report.externalId, "project": report.project,
                        "subtask": report.subtask, "source": "velocity"]
                    if let handle = report.jumpHandle { args["jumpHandle"] = handle }
                    _ = try await client.call(.report, args)
                }
                for id in diff.resolve { _ = try await client.call(.resolve, ["token": token, "externalId": id]) }
                for (project, windows) in workspaceChanges {
                    let list: [[String: Any]] = windows.map { w in
                        var d: [String: Any] = ["key": w.key, "kind": w.kind, "app": w.app, "title": w.title]
                        if let state = w.state { d["state"] = state }
                        if let task = w.task { d["task"] = task }
                        if let sig = w.sig { d["sig"] = sig }
                        return d
                    }
                    _ = try await client.call(.workspace, ["token": token, "project": project, "windows": list, "source": "velocity"])
                }
            } catch {
                // The next scan re-reports whatever still differs; the board's
                // 24h budget sweeps anything this Mac never manages to resolve.
                reporter = JuliaReporter(latch: reporter.latch)
                workspace = [:]
                notice?(error.localizedDescription)
            }
        }
    }

    private func persist() {
        let reports = reporter.current.values.sorted { $0.externalId < $1.externalId }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(reports) { try? data.write(to: store, options: .atomic) }
    }

    /// velocity://focus?handle=<jump handle> — the board sending him back to the
    /// exact terminal. Resolution is the notification's: same process launch,
    /// same window, same task, or nothing.
    static func handle(in url: URL) -> String? {
        guard url.scheme == "velocity", url.host == "focus",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let handle = items.first(where: { $0.name == "handle" })?.value, !handle.isEmpty else { return nil }
        return handle
    }
    func open(_ url: URL) {
        guard url.scheme == "velocity" else { return }
        let entries = allEntries?() ?? []
        // velocity://foreground?project=X — everything for that project, at once.
        if url.host == "foreground", let project = JuliaWorkspace.query(in: url, "project") {
            guard let group = JuliaWorkspace.group(for: project, names: projectNames[project], in: entries) else {
                notice?("Nothing is open for \(project) right now."); return
            }
            Task { @MainActor [weak self] in
                if await self?.foreground?(group.entries, group.lead) != true { _ = await WindowCatalog.focus(group.lead) }
            }
            return
        }
        // velocity://terminal?path=/abs/dir — a new terminal in that project.
        if url.host == "terminal" {
            guard let dir = JuliaWorkspace.terminalDirectory(JuliaWorkspace.query(in: url, "path")) else {
                notice?("That project has no folder on this Mac to open a terminal in."); return
            }
            let running = NSWorkspace.shared.runningApplications.compactMap { app -> (pid: pid_t, bundle: String)? in
                guard let id = app.bundleIdentifier, WindowCatalog.terminalIDs.contains(id) else { return nil }
                return (app.processIdentifier, id)
            }
            let bundle = JuliaWorkspace.preferredTerminal(entries, running: running)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: config) { [weak self] _, error in
                if let error { Task { @MainActor in self?.notice?("Couldn’t open a terminal there: " + error.localizedDescription) } }
            }
            return
        }
        // velocity://focus?sig=term:~/projects/x — the terminal in that folder (an answer's conversation).
        if url.host == "focus", JuliaWorkspace.query(in: url, "handle") == nil, let sig = JuliaWorkspace.query(in: url, "sig") {
            // The same lookup the handle path uses: exact folder, then folder NAME, then a
            // parent/child. (This branch kept its own exact-only match after that helper
            // was written, so what2do's "convex-app" tab was never found — silently.)
            guard let entry = Self.terminal(inFolder: sig, in: entries) else { notice?("That conversation's terminal is no longer open."); return }
            raise(entry)
            return
        }
        // velocity://focus?project=X&window=<key> — one of them.
        if url.host == "focus", let key = JuliaWorkspace.query(in: url, "window") {
            guard let entry = entries.first(where: { $0.id == key }) else { notice?("That window is no longer open."); return }
            raise(entry)
            return
        }
        guard let handle = Self.handle(in: url) else { return }
        guard let destination = JuliaJumpHandle.decode(handle) else { notice?("That jump link isn’t one Velocity made."); return }
        // THE TAB, NOT ITS TITLE. A handle remembers the title it was minted under, and
        // that is right for "Action Required" (the title sits still while it waits). But
        // an agent's title changes every few seconds — a handle minted while it WORKED
        // matched nothing by the time he clicked Open, and nothing happened. So: the
        // exact match first; then the same tab by identity; then any terminal in the
        // conversation's folder. Never a different process, never by title across windows.
        guard let entry = destination.liveEntry() ?? Self.sameTab(destination, in: entries)
                ?? JuliaWorkspace.query(in: url, "sig").flatMap({ Self.terminal(inFolder: $0, in: entries) }) else {
            notice?("That terminal closed since Julia was told about it."); return
        }
        // Straight to the terminal — the palette never shows (see raise).
        raise(entry)
    }
}

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
    /// What the agent is asking, read from the tab's screen (AttentionPrompt), and which harness.
    var prompt: String? = nil
    var harness: String? = nil
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

    /// `screen`: for a waiting tab, its tty and what is on it (nil in tests and when
    /// Terminal cannot be asked). The tty rides in the handle; the question rides beside it.
    @MainActor static func reports(_ entries: [WindowEntry], launch: (pid_t) -> Date?, screen: ((WindowEntry) -> (tty: String?, contents: String?))? = nil) -> [JuliaReport] {
        AttentionNotifications.waiting(entries).map { key, entry in
            let presentation = AttentionPresentation(entry)
            let seen = screen?(entry)
            let handle = launch(entry.pid)
                .flatMap { AttentionDestination(entry: entry, launch: $0, tty: seen?.tty) }
                .flatMap(JuliaJumpHandle.encode)
            return JuliaReport(externalId: JuliaJumpHandle.id(key), project: presentation.project,
                subtask: presentation.task, jumpHandle: handle,
                prompt: seen?.contents.flatMap { AttentionPrompt.extract($0) }, harness: AttentionPrompt.harness(title: entry.title))
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
        try await call(path: function.rawValue, kind: function.kind, args)
    }
    /// The same transport for prefrontal/1 functions (PrefrontalFunction) — all mutations.
    func call(path: String, kind: String = "mutation", _ args: [String: Any]) async throws -> Any? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/\(kind)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "args": args, "format": "json"])
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 200_000, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Julia answered with something that isn’t JSON.")
        }
        if body["status"] as? String == "success" { return body["value"] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = (body["errorMessage"] as? String).map { String($0.prefix(300)) } ?? "HTTP \(status)"
        throw Failure(message: "\(path) failed: \(detail)")
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
    private var firstSeen = FirstSeen()
    private var latch = JuliaWorkspace.WorkingLatch()
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
    /// prefrontal/1: commands addressed to this Mac arrive here by subscription.
    private var prefrontal: PrefrontalLink?
    private var machineObservers: [NSObjectProtocol] = []
    /// The last `now` sent: an activation is reported once, not on every 1 s activity tick.
    private var lastNow: (app: String, key: String)?

    init() {
        token = JuliaKeychain.token()
        state = token.isEmpty ? .unpaired : .paired
        if let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode([JuliaReport].self, from: data) {
            reporter.restore(saved, now: Date())
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, machineState) in [(NSWorkspace.willSleepNotification, "asleep"), (NSWorkspace.didWakeNotification, "awake"),
                                     (NSWorkspace.screensDidSleepNotification, "asleep"), (NSWorkspace.screensDidWakeNotification, "awake")] {
            machineObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportMachineState(machineState) }
            })
        }
        if state == .paired { joinPrefrontal() }
    }

    // MARK: prefrontal/1 — this Mac as ONE machine

    private static var harvesterVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// Register this machine (hardware id, name, what Velocity can sense and do) and
    /// subscribe to its command queue. On every paired launch and on pairing success.
    private func joinPrefrontal() {
        guard state == .paired, let client = try? JuliaClient() else { return }
        let args: [String: Any] = ["token": token, "protocol": PrefrontalFunction.protocolVersion,
            "machineId": MachineIdentity.machineId, "name": MachineIdentity.name, "platform": MachineIdentity.platform,
            "harvester": ["name": "velocity", "version": Self.harvesterVersion], "capabilities": PrefrontalFunction.capabilities]
        Task { @MainActor in
            do {
                _ = try await client.call(path: PrefrontalFunction.register, args)
                JuliaLog.note("prefrontal: registered \(MachineIdentity.name) as \(MachineIdentity.machineId.prefix(8)) (velocity \(Self.harvesterVersion))")
            } catch { JuliaLog.note("prefrontal: register failed: \(error.localizedDescription.prefix(200))") }
        }
        if prefrontal == nil {
            let link = PrefrontalLink(endpoint: client.endpoint)
            link.perform = { [weak self] command in await self?.perform(command) ?? .failed(class: "unavailable", why: "Velocity is shutting down.") }
            prefrontal = link
        }
        prefrontal?.start(token: token)
    }
    private func leavePrefrontal() { prefrontal?.stop() }

    private func reportMachineState(_ machineState: String) {
        guard state == .paired, let client = try? JuliaClient() else { return }
        JuliaLog.note("prefrontal: machine \(machineState)")
        let args: [String: Any] = ["token": token, "machineId": MachineIdentity.machineId, "state": machineState]
        Task { do { _ = try await client.call(path: PrefrontalFunction.machineState, args) } catch { JuliaLog.note("prefrontal: machineState failed: \(error.localizedDescription.prefix(200))") } }
    }

    /// NOW: what his hands are on. Sent when the frontmost window changes (App.swift's
    /// activation tracking hands the focused entry here) — an event, never a timer.
    func now(_ entry: WindowEntry) {
        guard state == .paired else { return }
        let sig = JuliaWorkspace.signature(entry)
        let key = sig
        if let last = lastNow, last.app == entry.appName, last.key == key { return }
        lastNow = (entry.appName, key)
        guard let client = try? JuliaClient() else { return }
        var args: [String: Any] = ["token": token, "machineId": MachineIdentity.machineId, "app": entry.appName, "idle": false]
        if !JuliaWorkspace.looksSensitive(entry.title) { args["title"] = String(entry.title.prefix(140)) }
        if !sig.hasPrefix("win:") { args["sig"] = sig }
        Task { do { _ = try await client.call(path: PrefrontalFunction.now, args) } catch { JuliaLog.note("prefrontal: now failed: \(error.localizedDescription.prefix(200))") } }
    }

    /// A command from another surface, run through the same velocity:// handling a
    /// same-machine click uses — and RESOLVED ONLY WITH ITS RECEIPT: how the outcome was
    /// seen, or why it could not be. `wake` and `doctor` answer for themselves.
    private func perform(_ command: PrefrontalCommand) async -> ActReceipt {
        switch command.kind {
        case "wake": return .verified(method: "self", observed: "Velocity is awake on \(MachineIdentity.name)")
        case "doctor": return Self.doctorReceipt()
        default: break
        }
        guard let url = command.velocityURL else { return .failed(class: "invalid", why: "Velocity can't run a \(command.kind) with those arguments.") }
        return await perform(url)
    }

    /// THE DOCTOR'S QUESTION: which transcript folders can this Mac's harvester read? The
    /// answer is the act's own evidence (`self`); none readable is a failure, said plainly.
    static func doctorReceipt() -> ActReceipt {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["~/.claude/projects", "~/.codex/sessions"]
        var readable: [String] = [], unreadable: [String] = []
        for root in roots {
            let path = home + root.dropFirst()
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil { readable.append(root) } else { unreadable.append(root) }
        }
        guard !readable.isEmpty else { return .failed(class: "unavailable", why: "no transcript folder is readable (\(unreadable.joined(separator: ", ")))") }
        return .verified(method: "self", observed: "readable: \(readable.joined(separator: ", "))" + (unreadable.isEmpty ? "" : " · not readable: \(unreadable.joined(separator: ", "))"))
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
            pairingTask?.cancel(); leavePrefrontal(); JuliaKeychain.forget(); token = ""; state = .unpaired
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
                        self?.joinPrefrontal()
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
            "askedAt": e.askedAt, "done": e.done, "machineId": MachineIdentity.machineId]
        if let cwd = e.cwd { args["cwd"] = cwd }
        if let answer = e.answer { args["answer"] = answer }
        if let at = e.answeredAt { args["answeredAt"] = at }
        // THE TAB, NOT THE FOLDER: two agents can share a folder; the tty is the one.
        let tty = ConversationTTY.tty(source: e.source, sessionId: e.sessionId, cwd: e.cwd, startedAt: e.askedAt)
        let entries = allEntries?() ?? []
        JuliaLog.note("report \(e.source) \(e.sessionId.prefix(8)) cwd=\(e.cwd ?? "-") tty=\(tty ?? "unresolved")")
        if let tty, let jump = Self.jumpHandle(onTTY: tty, in: entries) { args["jump"] = jump }
        else if let cwd = e.cwd, let jump = Self.jumpHandle(forFolder: cwd, in: entries, tty: tty) { args["jump"] = jump }
        Task { _ = try? await client.call(.exchange, args) }
    }

    /// RAISE A WINDOW FROM THE BACKGROUND. macOS 14 lets an app hand activation to
    /// another only while it is itself active (cooperative activation), and Velocity is
    /// not active when Julia sends a URL — so WindowCatalog.focus quietly failed whenever
    /// the target was not already frontmost (measured: works with Terminal in front,
    /// nothing with Chrome in front; "clicking open in what2do doesn't bring it to the
    /// forefront"). Velocity is a menu-bar app with nothing to show, so activating it for
    /// a beat is invisible; then it yields to the target and steps back.
    /// The colour of the glow around what comes forward — the state's colour, as on the
    /// strip (blue = an answer, orange = it needs him), else a plain white ring.
    var glowTint: NSColor = .white
    static func tint(named name: String?) -> NSColor {
        switch name { case "blue": return .systemBlue; case "orange": return .systemOrange; default: return .white }
    }

    private func raise(_ entry: WindowEntry) async -> ActReceipt {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else {
            return .failed(class: "stale", why: "That app is no longer running.")
        }
        let tint = glowTint
        let name = "“\(entry.title.prefix(40))”"
        let where_ = { (wid: CGWindowID) -> String in WindowRaise.spaceNumber(of: wid).map { " on Space \($0)" } ?? "" }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid {
            if await !WindowCatalog.focus(entry) { openEntry?(entry) }
            if let el = entry.element, let wid = WindowRaise.windowID(of: el) {
                WindowRaise.glow(windowID: wid, tint: tint)
                if WindowRaise.isTop(windowID: wid, pid: entry.pid) { return .verified(method: "z-order", observed: "\(name) topmost\(where_(wid))") }
            }
            return .verified(method: "app-activated", observed: "\(app.localizedName ?? "the app") was already in front; \(name) selected, window not verified")
        }
        // ONE WINDOW, NOT THE APP: the window server puts exactly this window in front
        // ("i don't like that open foregrounds the entire terminal app"). Verified by the
        // frontmost app; the Launch Services path below is the fallback.
        JuliaLog.note("raise: element=\(entry.element != nil) wid=\(entry.element.flatMap(WindowRaise.windowID(of:)).map(String.init) ?? "nil") skylight=\(WindowRaise.available)")
        if let el = entry.element, let wid = WindowRaise.windowID(of: el) {
            if entry.minimized { AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            if await WindowRaise.bring(pid: entry.pid, windowID: wid, element: el) {
                if entry.tab != nil || entry.browserTab != nil { _ = await WindowCatalog.focus(entry) }
                WindowRaise.glow(windowID: wid, tint: tint)
                JuliaLog.note("raised one window: \(app.localizedName ?? "") \(name) (verified)")
                return .verified(method: "z-order", observed: "\(name) topmost\(where_(wid))")
            }
            JuliaLog.note("single-window raise NOT verified for \(name); falling back to app activation")
        }
        // A background app's own activation requests are ignored on macOS 14 — measured:
        // NSApp.activate() never took, app.activate() reported success while the target
        // stayed behind Chrome, and `open -g` did the same. What IS honoured from the
        // background is a Launch Services open WITH activation — what `open -a` does.
        // So: bring the app forward that way, then raise the exact window and tab.
        guard let url = app.bundleURL else { return .failed(class: "unavailable", why: "\(app.localizedName ?? "That app") has no bundle to activate.") }
        app.unhide()
        if let window = entry.element { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        let opened: Bool = await withCheckedContinuation { c in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in c.resume(returning: error == nil) }
        }
        guard opened else { return .failed(class: "unavailable", why: "Couldn’t bring \(app.localizedName ?? "that app") forward.") }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let window = entry.element {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if entry.tab != nil || entry.browserTab != nil { _ = await WindowCatalog.focus(entry) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else {
            return .failed(class: "uncertain", why: "\(app.localizedName ?? "That app") didn’t come to the front.")
        }
        if let el = entry.element, let wid = WindowRaise.windowID(of: el) {
            WindowRaise.glow(windowID: wid, tint: tint)
            if WindowRaise.isTop(windowID: wid, pid: entry.pid) { return .verified(method: "z-order", observed: "\(name) topmost\(where_(wid)) (after app activation)") }
        }
        return .verified(method: "app-activated", observed: "the whole app came forward; window not verified")
    }

    /// Bring an app forward from the background — Launch Services with activation, the
    /// only request macOS 14 honours from a non-active app (see raise). Waits until it is.
    @MainActor func activate(pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, let url = app.bundleURL else { return }
        app.unhide()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in c.resume() }
        }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try? await Task.sleep(for: .milliseconds(50))
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

    /// The exact tab on that tty — the conversation's own terminal.
    static func jumpHandle(onTTY tty: String, in entries: [WindowEntry]) -> String? {
        guard let entry = ConversationTTY.entry(onTTY: tty, in: entries),
              let launch = NSRunningApplication(processIdentifier: entry.pid)?.launchDate,
              let destination = AttentionDestination(entry: entry, launch: launch, tty: tty) else { return nil }
        return JuliaJumpHandle.encode(destination)
    }
    /// The terminal sitting in that folder — preferring one whose title shows an agent.
    /// A guess when there are several; the tty rides along so a later resolve can do better.
    static func jumpHandle(forFolder cwd: String, in entries: [WindowEntry], tty: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sig = "term:" + (cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd).lowercased()
        let here = entries.filter { $0.terminal && JuliaWorkspace.signature($0) == sig }
        guard let entry = here.first(where: { $0.attention != .none }) ?? here.first,
              let launch = NSRunningApplication(processIdentifier: entry.pid)?.launchDate,
              let destination = AttentionDestination(entry: entry, launch: launch, tty: tty) else { return nil }
        return JuliaJumpHandle.encode(destination)
    }
    /// Resolve a destination: by tty first (exact, survives every title change), then the
    /// live window/tab, then the same tab by identity.
    static func resolve(_ d: AttentionDestination, in entries: [WindowEntry]) -> WindowEntry? {
        if let tty = d.tty, let e = ConversationTTY.entry(onTTY: tty, in: entries) { return e }
        return d.liveEntry() ?? sameTab(d, in: entries)
    }

    /// Called after every scan: `attention` is what the notifier sees (done
    /// objectives filtered out); `all` is every window, for the per-project manifest.
    func observe(attention entries: [WindowEntry], all: [WindowEntry] = []) {
        guard state == .paired else { return }
        if answers == nil { answers = AnswerWatcher { [weak self] exchange in self?.report(exchange) } }
        // The screen of every waiting tab: the tabs once, then one event per waiting tab.
        var tabs: [ConversationTTY.Tab]?
        let reports = JuliaReporter.reports(entries, launch: { NSRunningApplication(processIdentifier: $0)?.launchDate }) { entry in
            if tabs == nil { tabs = ConversationTTY.terminalTabs() }
            let tty = ConversationTTY.tty(of: entry, in: all, tabs: tabs)
            let contents = tty.flatMap(ConversationTTY.contents(ofTTY:))
            JuliaLog.note("asking: “\(entry.title.prefix(50))” tty=\(tty ?? "unresolved") screen=\(contents.map { "\($0.count) chars" } ?? "none") tabs=\(tabs?.count ?? 0) isTab=\(entry.isTab) key=\(entry.windowKey ?? "nil")")
            return (tty, contents)
        }
        pendingReports = reports
        if !projectTitles.isEmpty {
            let raw = JuliaWorkspace.manifest(names: projectNames, order: projectTitles, entries: all)
            let now = Date()
            let current = firstSeen.stamp(raw.mapValues { latch.apply($0, now: now) }, now: now)
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
                        "subtask": report.subtask, "source": "velocity", "machineId": MachineIdentity.machineId]
                    if let handle = report.jumpHandle { args["jumpHandle"] = handle }
                    if let prompt = report.prompt { args["prompt"] = prompt }
                    if let harness = report.harness { args["harness"] = harness }
                    _ = try await client.call(.report, args)
                }
                for id in diff.resolve { _ = try await client.call(.resolve, ["token": token, "externalId": id]) }
                for (project, windows) in workspaceChanges {
                    _ = try await client.call(.workspace, ["token": token, "project": project, "windows": Self.wire(windows), "source": "velocity"])
                }
                // DUAL-WRITE (prefrontal/1): the same manifest, under this machine's id, as ONE
                // snapshot — every non-empty bucket plus `*`. Best-effort while the component
                // lands: a refusal here must not reset the board's reporter above.
                if !workspaceChanges.isEmpty {
                    do { _ = try await client.call(path: PrefrontalFunction.observe, ["token": token, "machineId": MachineIdentity.machineId, "buckets": Self.observation(workspace, order: projectTitles)]) }
                    catch { JuliaLog.note("prefrontal: observe failed: \(error.localizedDescription.prefix(200))") }
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
    /// A window list as the wire carries it (attention:workspace and prefrontal:observe agree).
    /// No `tty`: naming a Terminal tab's tty costs an Apple Events round trip per scan.
    static func wire(_ windows: [JuliaWindow]) -> [[String: Any]] {
        windows.map { w in
            var d: [String: Any] = ["key": w.key, "kind": w.kind, "app": w.app, "title": w.title]
            if let state = w.state { d["state"] = state }
            if let task = w.task { d["task"] = task }
            if let sig = w.sig { d["sig"] = sig }
            if let since = w.since { d["since"] = since }
            return d
        }
    }
    /// prefrontal/1 WindowsReport.buckets: non-empty project buckets in his order, `*`
    /// always, at most MAX_BUCKETS_PER_MACHINE (12) — the component's read budget.
    static func observation(_ manifest: [String: [JuliaWindow]], order: [String] = [], limit: Int = 12) -> [[String: Any]] {
        let ordered = order + manifest.keys.filter { $0 != "*" && !order.contains($0) }.sorted()
        var buckets: [[String: Any]] = ordered.compactMap { name in
            guard let windows = manifest[name], !windows.isEmpty else { return nil }
            return ["bucket": name, "windows": wire(Array(windows.prefix(40)))]
        }
        buckets = Array(buckets.prefix(limit - 1))
        buckets.append(["bucket": "*", "windows": wire(Array((manifest["*"] ?? []).prefix(40)))])
        return buckets
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
        // velocity://run?id=<commandId> — the same-machine NUDGE for a row Julia.app just
        // enqueued to this machine: the row is the act; the URL only shortens the wait.
        if url.host == "run" {
            guard let id = JuliaWorkspace.query(in: url, "id"), !id.isEmpty else { notice?("That run link names no command."); return }
            guard let prefrontal, state == .paired else { notice?("Connect Velocity to Julia first."); return }
            prefrontal.nudge(id: id)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let receipt = await self.perform(url)
            JuliaLog.note("act \(url.host ?? "?") receipt: \(receipt.line)")
            // A media pause that could not be measured is not worth a notice at every mic hold.
            if case .failed(let cls, let why) = receipt, !(url.host == "media" && cls == "uncertain") { self.notice?(why) }
        }
    }
    /// The one place a velocity:// URL is acted on — a same-machine click and a
    /// prefrontal command run through the same branches. RESOLVES WITH THE RECEIPT: every
    /// branch awaits its own outcome and says how it saw it done, or why it did not.
    func perform(_ url: URL) async -> ActReceipt {
        // The glow's colour rides on every act: blue = an answer, orange = it needs him.
        glowTint = Self.tint(named: JuliaWorkspace.query(in: url, "glow"))
        WindowRaise.currentTint = glowTint
        guard url.scheme == "velocity" else { return .failed(class: "invalid", why: "Not a velocity:// URL.") }
        JuliaLog.note("act \(url.host ?? "?") received")
        let entries = allEntries?() ?? []
        // velocity://foreground?project=X — everything for that project, at once.
        if url.host == "foreground", let project = JuliaWorkspace.query(in: url, "project") {
            // Julia's attribution first (his placements, Jev's judgments — windows whose
            // titles say nothing about the project), then whatever the names match.
            let wanted = Set((JuliaWorkspace.query(in: url, "windows") ?? "").split(separator: ",").map(String.init))
            let placed = entries.filter { wanted.contains($0.id) }
            let named = JuliaWorkspace.group(for: project, names: projectNames[project], in: entries)
            var members = placed
            for e in named?.entries ?? [] where !members.contains(where: { $0.id == e.id }) { members.append(e) }
            let missing = wanted.count - placed.count
            JuliaLog.note("foreground \(project): \(wanted.count) keys from Julia (\(placed.count) open, \(missing) not found), \(named?.entries.count ?? 0) by name → \(members.count) windows")
            guard let lead = members.first(where: \.terminal) ?? members.first else {
                return .failed(class: "stale", why: "Nothing is open for \(project) right now.")
            }
            let grouped = await foreground?(members, lead) ?? false
            if !grouped { _ = await WindowCatalog.focus(lead) }
            let leadName = "“\(lead.title.prefix(40))”"
            if let el = lead.element, let wid = WindowRaise.windowID(of: el), WindowRaise.isTop(windowID: wid, pid: lead.pid) {
                return .verified(method: "z-order", observed: "\(members.count) window\(members.count == 1 ? "" : "s") of \(project) forward; \(leadName) topmost")
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == lead.pid {
                return .verified(method: "app-activated", observed: "\(members.count) window\(members.count == 1 ? "" : "s") of \(project) forward; \(lead.appName) active, \(leadName) not verified topmost")
            }
            return .failed(class: "uncertain", why: "Raised \(members.count) window\(members.count == 1 ? "" : "s") for \(project), but \(lead.appName) isn’t in front.")
        }
        // velocity://media?pause=1 | resume=1 — quiet the room while he talks.
        if url.host == "media" {
            let pausing = JuliaWorkspace.query(in: url, "pause") != nil
            let before = JuliaHands.loudProcesses()
            // The ⏯ key first — instant, needs no setting — then the precise per-tab /
            // per-player path OFF the main thread (scripting 60 tabs takes seconds).
            if pausing { JuliaHands.pauseByKey(ifAnyPlaying: entries) } else { JuliaHands.resumeByKey() }
            let problem = await Task.detached(priority: .userInitiated) { pausing ? JuliaHands.pauseVideos() : JuliaHands.resumeVideos() }.value
            if let problem, problem.contains("turned off") {
                notice?("For per-tab pausing, turn on Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events.")
            }
            if !pausing { return .verified(method: "self", observed: "resume sent to what was paused" + (problem.map { " · " + $0 } ?? "")) }
            // THE FACT: fewer processes putting out sound than before the pause.
            guard !before.isEmpty else { return .verified(method: "audio-silent", observed: "nothing was playing") }
            try? await Task.sleep(for: .milliseconds(400))
            let after = JuliaHands.loudProcesses()
            if after.count < before.count { return .verified(method: "audio-silent", observed: "\(before.count - after.count) of \(before.count) sound source\(before.count == 1 ? "" : "s") went quiet") }
            return .failed(class: "uncertain", why: "\(after.count) process\(after.count == 1 ? "" : "es") still putting out sound after the pause" + (problem.map { " · " + $0 } ?? ""))
        }
        // velocity://type?sig=…&handle=…&text=…&enter=1 — his words, into THAT conversation.
        // velocity://approve?handle=… — "Yes" to what that tab is asking. The question must
        // still be on its screen; the harness's own keys go in only once the tab is the
        // front window's selected one; verified by the question LEAVING the screen.
        if url.host == "approve" {
            guard let tty = JuliaJumpHandle.decode(JuliaWorkspace.query(in: url, "handle") ?? "")?.tty else {
                return .failed(class: "invalid", why: "That question’s tab isn’t known by its tty — open it and answer there.")
            }
            guard let target = ConversationTTY.target(onTTY: tty) else { return .failed(class: "stale", why: "That tab is gone.") }
            guard let before = ConversationTTY.contents(ofTTY: tty), let asking = AttentionPrompt.extract(before) else {
                return .failed(class: "stale", why: "Nothing is being asked on that tab any more.")
            }
            let harness = AttentionPrompt.harness(title: target.entry.title)
            let keys = AttentionPrompt.yesKeys(harness: harness)
            JuliaLog.note("approve → tty \(tty) harness=\(harness ?? "?") keys=\(keys.text.isEmpty ? "Return" : keys.text)")
            let ok = await JuliaHands.type(keys.text, enter: keys.enter, into: target.entry) { [weak self] in
                guard let wid = target.select() else { return false }
                if await WindowRaise.bring(pid: target.entry.pid, windowID: wid) { WindowRaise.glow(windowID: wid, tint: self?.glowTint ?? .white) }
                else { await self?.activate(pid: target.entry.pid); _ = target.select() }
                for _ in 0..<10 {
                    if ConversationTTY.isFront(tty: tty) { return true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }
            guard ok else { return .failed(class: "uncertain", why: "Couldn’t answer that tab (it didn’t come to the front) — nothing was typed.") }
            // The receipt is the question leaving the screen, within two seconds.
            let lastLine = asking.components(separatedBy: "\n").last ?? asking
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(200))
                if let now = ConversationTTY.contents(ofTTY: tty), AttentionPrompt.extract(now) != asking, !String(now.suffix(600)).contains(lastLine) {
                    return .verified(method: "prompt-cleared", observed: "the question left \(tty)’s screen after \(keys.text.isEmpty ? "Return" : "“\(keys.text)”")")
                }
            }
            return .verified(method: "keys-posted", observed: "\(keys.text.isEmpty ? "Return" : "“\(keys.text)”") into \(tty); the question may still be showing")
        }
        if url.host == "type", let text = JuliaWorkspace.query(in: url, "text") {
            let enter = JuliaWorkspace.query(in: url, "enter") == "1"
            var entry: WindowEntry?
            let tty = JuliaJumpHandle.decode(JuliaWorkspace.query(in: url, "handle") ?? "")?.tty ?? JuliaWorkspace.query(in: url, "tty")
            if let tty, let target = ConversationTTY.target(onTTY: tty) {
                // THE TAB ITSELF, wherever it is: Terminal selects it, Velocity brings Terminal
                // forward, the words go in. No folder guess, no catalog, no title.
                JuliaLog.note("type → tty \(tty) “\(target.entry.title.prefix(60))”")
                let ok = await JuliaHands.type(text, enter: enter, into: target.entry) { [weak self] in
                    guard let wid = target.select() else { return false }
                    // The one Terminal window, in front — not every Terminal window.
                    if await WindowRaise.bring(pid: target.entry.pid, windowID: wid) { WindowRaise.glow(windowID: wid, tint: self?.glowTint ?? .white) }
                    else { await self?.activate(pid: target.entry.pid); _ = target.select() }
                    // THE TAB, in front, verified — up to a second for a Space to switch.
                    for _ in 0..<10 {
                        if ConversationTTY.isFront(tty: tty) { return true }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    JuliaLog.note("tty \(tty) never became the front window's selected tab")
                    return false
                }
                JuliaLog.note(ok ? "typed \(text.count) chars\(enter ? " + Enter" : "") into tty \(tty)" : "type FAILED: tty \(tty) — that tab never came to the front")
                guard ok else { return .failed(class: "uncertain", why: "Couldn’t type into that terminal (it didn’t come to the front) — nothing was typed.") }
                return await Self.typedReceipt(text: text, enter: enter, into: tty)
            }
            if let handle = JuliaWorkspace.query(in: url, "handle"), let d = JuliaJumpHandle.decode(handle) { entry = Self.resolve(d, in: entries) }
            if entry == nil, let sig = JuliaWorkspace.query(in: url, "sig") {
                // A folder is a guess. With ONE terminal there it is a safe one; with several,
                // typing into "the first" is how his words reached the wrong agent.
                let here = entries.filter { $0.terminal && JuliaWorkspace.signature($0) == sig.lowercased() }
                if here.count <= 1 { entry = Self.terminal(inFolder: sig, in: entries) }
                else { return .failed(class: "conflict", why: "\(here.count) terminals sit in that folder and I can't tell which one answered — nothing was typed.") }
            }
            guard let target = entry else {
                JuliaLog.note("type: no terminal resolved (handle=\(JuliaWorkspace.query(in: url, "handle") != nil) tty=\(JuliaWorkspace.query(in: url, "tty") ?? "-") sig=\(JuliaWorkspace.query(in: url, "sig") ?? "-"))")
                return .failed(class: "unavailable", why: "That conversation's terminal is no longer open — nothing was typed.")
            }
            JuliaLog.note("type → \(target.appName) “\(target.title.prefix(60))”")
            let ok = await JuliaHands.type(text, enter: enter, into: target) { [weak self] in
                guard let self else { return false }
                _ = await self.raise(target)
                try? await Task.sleep(for: .milliseconds(500))
                return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
            }
            JuliaLog.note(ok ? "typed \(text.count) chars\(enter ? " + Enter" : "") into “\(target.title.prefix(60))”" : "type FAILED: “\(target.title.prefix(60))” never came to the front")
            guard ok else { return .failed(class: "uncertain", why: "Couldn’t type into that terminal (it didn’t come to the front) — nothing was typed.") }
            return await Self.typedReceipt(text: text, enter: enter, into: "“\(target.title.prefix(40))”")
        }
        // velocity://terminal?path=/abs/dir — a new terminal in that project.
        if url.host == "terminal" {
            // create=1: a project with no folder yet gets one — ONLY under ~/Projects, never a
            // dotfolder, never nested inside another project's home ("i made a new project …
            // but i can't figure out how to add a terminal window to it to start an agent").
            if JuliaWorkspace.query(in: url, "create") == "1", let raw = JuliaWorkspace.query(in: url, "path") {
                let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").standardizedFileURL.path
                let url = URL(fileURLWithPath: raw).standardizedFileURL
                let parent = url.deletingLastPathComponent().path
                if parent == projects, !url.lastPathComponent.hasPrefix("."), !FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); JuliaLog.note("made folder \(url.lastPathComponent) under ~/Projects") }
                    catch { return .failed(class: "unavailable", why: "Couldn't make ~/Projects/\(url.lastPathComponent): \(error.localizedDescription)") }
                } else if parent != projects {
                    return .failed(class: "invalid", why: "A new project folder goes under ~/Projects only.")
                }
            }
            guard let dir = JuliaWorkspace.terminalDirectory(JuliaWorkspace.query(in: url, "path")) else {
                return .failed(class: "invalid", why: "That project has no folder on this Mac to open a terminal in.")
            }
            let running = NSWorkspace.shared.runningApplications.compactMap { app -> (pid: pid_t, bundle: String)? in
                guard let id = app.bundleIdentifier, WindowCatalog.terminalIDs.contains(id) else { return nil }
                return (app.processIdentifier, id)
            }
            let bundle = JuliaWorkspace.preferredTerminal(entries, running: running)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return .failed(class: "unavailable", why: "No terminal app is installed on this Mac.") }
            let before = ConversationTTY.shellTTYs(inFolder: dir.path)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = false
            let opened: Bool = await withCheckedContinuation { c in
                NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: config) { _, error in c.resume(returning: error == nil) }
            }
            guard opened else { return .failed(class: "unavailable", why: "Couldn’t open a terminal in \(dir.lastPathComponent).") }
            // THE FACT: a new shell tty in that folder, within 3 s.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(300))
                if let fresh = ConversationTTY.shellTTYs(inFolder: dir.path).subtracting(before).sorted().first {
                    return .verified(method: "tty-appeared", observed: "\(fresh) opened in \(dir.lastPathComponent)")
                }
            }
            return .failed(class: "uncertain", why: "Asked \(app.deletingPathExtension().lastPathComponent) to open \(dir.lastPathComponent); no new shell appeared there within 3 s.")
        }
        // velocity://focus?sig=term:~/projects/x — the terminal in that folder (an answer's conversation).
        if url.host == "focus", JuliaWorkspace.query(in: url, "handle") == nil, let sig = JuliaWorkspace.query(in: url, "sig") {
            // The same lookup the handle path uses: exact folder, then folder NAME, then a
            // parent/child. (This branch kept its own exact-only match after that helper
            // was written, so what2do's "convex-app" tab was never found — silently.)
            guard let entry = Self.terminal(inFolder: sig, in: entries) else { return .failed(class: "unavailable", why: "That conversation's terminal is no longer open.") }
            return await raise(entry)
        }
        // velocity://focus?project=X&window=<key> — one of them.
        if url.host == "focus", let key = JuliaWorkspace.query(in: url, "window") {
            guard let entry = entries.first(where: { $0.id == key }) else { return .failed(class: "stale", why: "That window is no longer open.") }
            return await raise(entry)
        }
        guard let handle = Self.handle(in: url) else { return .failed(class: "unsupported", why: "Velocity doesn’t know what to do with \(url.host ?? "that").") }
        guard let destination = JuliaJumpHandle.decode(handle) else { return .failed(class: "invalid", why: "That jump link isn’t one Velocity made.") }
        // THE TAB, NOT ITS TITLE. A handle remembers the title it was minted under, and
        // that is right for "Action Required" (the title sits still while it waits). But
        // an agent's title changes every few seconds — a handle minted while it WORKED
        // matched nothing by the time he clicked Open, and nothing happened. So: the
        // exact match first; then the same tab by identity; then any terminal in the
        // conversation's folder. Never a different process, never by title across windows.
        // THE TAB ITSELF when the handle knows its tty: Terminal selects it (any Space), the
        // window server puts that one window in front, a ring shows where.
        if let tty = destination.tty, let target = ConversationTTY.target(onTTY: tty) {
            JuliaLog.note("act focus: tab found by tty")
            guard let wid = target.select() else { return .failed(class: "stale", why: "That tab moved since Julia was told about it.") }
            JuliaLog.note("act focus: tab selected")
            if await WindowRaise.bring(pid: target.entry.pid, windowID: wid) {
                WindowRaise.glow(windowID: wid, tint: glowTint)
                JuliaLog.note("opened tty \(tty) — one window (verified)")
                let space = WindowRaise.spaceNumber(of: wid).map { " on Space \($0)" } ?? ""
                if ConversationTTY.isFront(tty: tty) { return .verified(method: "tty-front", observed: "\(tty) is the selected tab of Terminal’s front window, topmost\(space)") }
                return .verified(method: "z-order", observed: "“\(target.entry.title.prefix(40))” topmost\(space); \(tty) not confirmed as its selected tab")
            }
            JuliaLog.note("opened tty \(tty): single-window raise NOT verified; activating Terminal")
            await activate(pid: target.entry.pid)
            _ = target.select()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.entry.pid else { return .failed(class: "uncertain", why: "Terminal didn’t come to the front.") }
            if ConversationTTY.isFront(tty: tty) { return .verified(method: "tty-front", observed: "Terminal activated; \(tty) is its front window’s selected tab") }
            return .verified(method: "app-activated", observed: "the whole app came forward; window not verified")
        }
        guard let entry = Self.resolve(destination, in: entries)
                ?? JuliaWorkspace.query(in: url, "sig").flatMap({ Self.terminal(inFolder: $0, in: entries) }) else {
            return .failed(class: "stale", why: "That terminal closed since Julia was told about it.")
        }
        // Straight to the terminal — the palette never shows (see raise).
        return await raise(entry)
    }

    /// The receipt for words that went in: `keys-posted` (what was posted, where) upgraded
    /// to `prompt-echoed` when Terminal's selected tab shows the tail of them — one
    /// AppleScript, given 200 ms; no answer in time leaves the method at what was seen.
    static func typedReceipt(text: String, enter: Bool, into where_: String) async -> ActReceipt {
        let posted = "\(text.count) chars\(enter ? " + Enter" : "") into \(where_)"
        let tail = String(text.suffix(40))
        let echoed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await Task.detached(priority: .userInitiated) { ConversationTTY.promptEchoes(tail: tail) }.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(200)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return echoed ? .verified(method: "prompt-echoed", observed: "the terminal shows the words — " + posted) : .verified(method: "keys-posted", observed: posted)
    }
}

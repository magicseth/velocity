import Foundation
import CoreServices

/// THE TRANSCRIPT PRIVACY LAW, on this side of the wire: prose only, and any line shaped
/// like a secret is REFUSED. The patterns are kept identical to SECRET_PATTERNS in
/// convexos/convex/lib/agentActivity.ts (which re-applies them server-side); the convexos
/// verifier compares the two sources.
enum TranscriptLaw {
    static let secretPatterns = ["sk-[A-Za-z0-9_-]{16,}", "\\bkey\\s*=", "Bearer "]
    static func line(_ raw: String) -> String? {
        let t = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let clipped = String(t.prefix(400))
        for p in secretPatterns where clipped.range(of: p, options: .regularExpression) != nil { return nil }
        return clipped
    }
}

// HE ASKED; IS THERE AN ANSWER?
//
// Seth, 2026-09-21: "i hop between terminals and chatgpt app and claude app, asking for
// things to be done. Then i want to know if there is an answer to my question… it has
// to be seamless, and really obvious that something is ready for my attention."
//
// Agents already write down everything needed: Claude Code marks a finished turn with
// stop_reason "end_turn"; Codex (its TUI — and the desktop app he calls ChatGPT is
// com.openai.codex) writes a "task_complete" event. So "is there an answer?" is a FACT
// in a file, and FSEvents says the moment that file changes. No polling: the watcher
// sleeps until a transcript is written, reads its tail, and tells Julia about the last
// question he asked — "working", then "answered" the second the turn ends.
//
// What it will not do: report programmatic runs (`codex exec` — reviewHelper spawns
// dozens; those are not questions HE asked), sub-agent sidechains, tool calls or tool
// results. His question and the agent's prose answer only, each through the same
// privacy law as every transcript read (AgentActivity.sanitizedLine).
//
// Claude desktop: its chats keep no readable transcript on this Mac, but its Cowork /
// local-agent sessions are Claude Code (entrypoint "sdk-ts") and the desktop writes their
// ids down (DesktopSessions.swift) — exactly those pass; every other SDK host's "sdk-ts"
// (Conductor, reviewHelper's "sdk-cli") stays out. ChatGPT desktop (com.openai.codex)
// writes its rollouts into ~/.codex/sessions with originator "Codex Desktop"; its guardian
// reviews and spawned sub-agents (thread_source != "user") are not his questions either.
//
// WHY THIS LIVES IN VELOCITY. Velocity is the Mac's senses and hands; Julia is the
// memory and the judgment; Julia.app is her face and senses nothing. Reading a local
// transcript is sensing. And only Velocity knows WHICH terminal tab a conversation is
// in, so only here can an answer carry a jump handle back to that exact tab.
struct Exchange: Equatable {
    var externalId: String
    var source: String
    var sessionId: String
    var cwd: String?
    var question: String
    var answer: String?
    var askedAt: Double
    var answeredAt: Double?
    var done: Bool
}

@MainActor
final class AnswerWatcher {
    private let report: (Exchange) -> Void
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var flush: Task<Void, Never>?
    private var last: [String: Exchange] = [:]          // per file: what Julia was last told
    private var questionAt: [String: UInt64] = [:]      // per file: byte offset of his current question
    private let roots: [String]

    init(report: @escaping (Exchange) -> Void) {
        self.report = report
        let home = NSHomeDirectory()
        roots = [home + "/.claude/projects", home + "/.codex/sessions", DesktopSessions.root].filter { FileManager.default.fileExists(atPath: $0) }
        start()
    }

    private func start() {
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<AnswerWatcher>.fromOpaque(info).takeUnretainedValue()
            // The desktop's session index changed: forget it; the next transcript read reloads it.
            if list.prefix(count).contains(where: { $0.hasPrefix(DesktopSessions.root) }) { DesktopSessions.invalidate() }
            let changed = list.prefix(count).filter { $0.hasSuffix(".jsonl") }
            if !changed.isEmpty { Task { @MainActor in watcher.touched(Array(changed)) } }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
        catchUp()
    }

    /// WHAT CHANGED WHILE NOBODY WATCHED. A restart (an update, a crash) drops every event
    /// between the old process and this one; a turn he typed in that gap is not seen until
    /// the agent writes again — which, once it has answered, may be never (measured: his
    /// paste landed 2 s before the new Velocity started watching, and the strip kept saying
    /// the old answer needed him). So read once, at launch, every transcript touched in the
    /// last hour. One read per launch — not a poll.
    private func catchUp() {
        let roots = self.roots
        Task.detached(priority: .utility) {
            let since = Date().addingTimeInterval(-3600)
            var recent: [String] = []
            for root in roots {
                guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in e where url.pathExtension == "jsonl" {
                    if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > since { recent.append(url.path) }
                }
            }
            guard !recent.isEmpty else { return }
            await MainActor.run { [weak self] in self?.touched(recent) }
        }
    }

    /// Transcripts are written many times a second while an agent works: gather, then read
    /// once. A THROTTLE, not a debounce: the first write schedules a read a second out and
    /// later writes join that batch. The old timer restarted on every write, and the
    /// moment he typed a reply the agent began writing constantly — so the read that
    /// tells Julia "he asked something new" (which clears the old answer) waited for a
    /// lull: measured 4–15 s of a stale answer on the strip.
    private func touched(_ paths: [String]) {
        pending.formUnion(paths)
        guard flush == nil else { return }
        flush = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !Task.isCancelled else { return }
            let batch = pending; pending = []
            for path in batch {
                let from = questionAt[path]
                let parsed = await Task.detached(priority: .utility) { Self.read(path, from: from) }.value
                JuliaLog.note("transcript \((path as NSString).lastPathComponent.prefix(24)) from=\(from.map(String.init) ?? "start") → \(parsed.map { "\($0.0.externalId.suffix(12)) answer=\($0.0.answer != nil) done=\($0.0.done)" } ?? "nothing")")
                guard let (e, offset) = parsed else { continue }
                questionAt[path] = offset
                guard last[path] != e else { continue }
                last[path] = e
                report(e)
            }
            flush = nil
            if !pending.isEmpty { touched([]) }   // writes that arrived during the read
        }
    }

    // MARK: reading a transcript's last exchange (pure; tested by scripts/answers.verify.ts)

    nonisolated static func parse(_ path: String) -> Exchange? { read(path, from: nil)?.0 }

    /// HIS QUESTION CAN BE MEGABYTES BACK. One agent turn writes tool output by the
    /// megabyte (measured: his last question sat 1.13 MB from the end of a 123 MB
    /// transcript, and a fixed 384 KB tail found nothing). So: read from where his
    /// current question is known to start; otherwise walk back in growing windows until
    /// one is found. Returns the exchange and the byte offset of its question, so the
    /// next change to this file reads only the turn since.
    nonisolated static func read(_ path: String, from known: UInt64?) -> (Exchange, UInt64)? {
        let size = fileSize(path)
        var starts: [UInt64] = []
        if let known, known < size { starts.append(known) }
        for window in [UInt64(524_288), 4_194_304, 33_554_432] { starts.append(size > window ? size - window : 0) }
        var tried: Set<UInt64> = []
        for start in starts where tried.insert(start).inserted {
            let rows = lines(path, from: start, dropPartialFirst: start != 0 && start != known)
            let texts = rows.map(\.text)
            let found = path.contains("/.codex/") ? codexIndexed(texts, path: path) : claudeIndexed(texts, path: path)
            if let (e, index) = found { return (e, rows[index].offset) }
            if start == 0 { break }
        }
        return nil
    }

    nonisolated private static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
    nonisolated private static func lines(_ path: String, from start: UInt64, dropPartialFirst: Bool) -> [(offset: UInt64, text: String)] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        var out: [(UInt64, String)] = []; var lineStart = 0; var first = true
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            for i in 0...bytes.count where i == bytes.count || bytes[i] == 0x0A {
                if i > lineStart, !(first && dropPartialFirst),
                   let text = String(bytes: UnsafeBufferPointer(rebasing: bytes[lineStart..<i]), encoding: .utf8) {
                    out.append((start + UInt64(lineStart), text))
                }
                first = false; lineStart = i + 1
            }
        }
        return out
    }

    /// Harness chatter is not his words: injected reminders, command wrappers, interrupts.
    /// A pasted screenshot arrives as "[Image #3]" and "[Image: source: /Users/…/9.png]".
    /// Those are attachments, not his words — and the second leaks a local path.
    /// A PASTE IS HIS TURN, ITS BODY IS NOT HIS WORDS: Claude Code wraps a long paste as
    /// "<pasted_content id=…>…</pasted_content>" — the answer to "paste me the token" —
    /// and that body can be exactly a secret (measured: a Cloudflare API token). The turn
    /// counts (his previous question is superseded, the strip stops saying it needs him);
    /// the body never leaves. Before this, a paste-only turn began with "<" and was thrown
    /// away as harness chatter, so the old answer sat on the strip as still needing him.
    nonisolated static func withoutAttachments(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)<pasted_content\b[^>]*>.*?</pasted_content>"#, with: "(pasted text)", options: .regularExpression)
            .replacingOccurrences(of: #"\[Image[^\]]*\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isHis(_ text: String) -> Bool {
        let t = withoutAttachments(text)
        return !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("[Request interrupted") && !t.hasPrefix("Caveat:") && !t.hasPrefix("This session is being continued")
    }

    nonisolated static func prose(_ raw: String, limit: Int) -> String {
        var kept: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            guard let clean = TranscriptLaw.line(line) else { continue }               // secret-shaped lines are refused
            kept.append(clean)
        }
        return String(kept.joined(separator: "\n").prefix(limit))
    }

    nonisolated static func claude(_ lines: [String], path: String) -> Exchange? { claudeIndexed(lines, path: path)?.0 }
    nonisolated static func claudeIndexed(_ lines: [String], path: String) -> (Exchange, Int)? {
        var questionIndex = 0
        var question: (text: String, at: Double, id: String)?; var cwd: String?; var session = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var answer: String?; var answeredAt: Double?; var done = false; var desktop = false
        for (index, line) in lines.enumerated() {
            guard let j = json(line), (j["isSidechain"] as? Bool) != true, let kind = j["type"] as? String,
                  let msg = j["message"] as? [String: Any] else { continue }
            // A PROGRAM ASKED, NOT HIM. Interactive sessions say entrypoint "cli"; the SDK /
            // headless runs that tools like reviewHelper spawn by the dozen say "sdk-cli".
            // (First live row was one: "You are an expert software architect providing…")
            // The one SDK host that IS him: Claude desktop's Cowork sessions ("sdk-ts"), and
            // only the session ids the desktop itself wrote down — Conductor says "sdk-ts" too.
            if let entry = j["entrypoint"] as? String, entry.hasPrefix("sdk") {
                guard entry == "sdk-ts", DesktopSessions.isClaudeDesktop((j["sessionId"] as? String) ?? session) else { return nil }
                desktop = true
            }
            if let c = j["cwd"] as? String { cwd = c }
            if let s = j["sessionId"] as? String { session = s }
            let at = (j["timestamp"] as? String).flatMap(iso) ?? 0
            if kind == "user" {
                var text = msg["content"] as? String ?? ""
                if text.isEmpty, let parts = msg["content"] as? [[String: Any]] {
                    if parts.contains(where: { ($0["type"] as? String) == "tool_result" }) { continue }   // a tool talking, not him
                    text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                let sentImage = text.contains("[Image")
                if sentImage, withoutAttachments(text).isEmpty { text = "(a screenshot, no words)" }
                guard isHis(text) else { continue }
                text = withoutAttachments(text)
                question = (text, at, (j["uuid"] as? String) ?? String(Int(at))); questionIndex = index
                answer = nil; answeredAt = nil; done = false                                  // a new question: start over
            } else if kind == "assistant", question != nil {
                let parts = msg["content"] as? [[String: Any]] ?? []
                let text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { answer = text; answeredAt = at }
                if (msg["stop_reason"] as? String) == "end_turn" { done = true } else if !parts.isEmpty { done = false }
            }
        }
        guard let q = question else { return nil }
        let asked = prose(q.text, limit: 600)
        guard !asked.isEmpty else { return nil }
        return (Exchange(externalId: "claude-cli:\(session):\(q.id)", source: desktop ? "Claude desktop" : "Claude Code", sessionId: session, cwd: cwd,
                        question: asked, answer: answer.map { prose($0, limit: 1500) }, askedAt: q.at, answeredAt: answeredAt, done: done && answer != nil), questionIndex)
    }

    nonisolated static func codex(_ lines: [String], path: String) -> Exchange? { codexIndexed(lines, path: path)?.0 }
    nonisolated static func codexIndexed(_ lines: [String], path: String) -> (Exchange, Int)? {
        var questionIndex = 0
        // The session's meta line sits at the head of the file, not in the tail.
        var cwd: String?; var session = ((path as NSString).lastPathComponent as NSString).deletingPathExtension; var origin = "cli"; var originator = ""
        if let head = head(path, bytes: 131_072).first(where: { $0.contains("\"session_meta\"") }), let j = json(head), let p = j["payload"] as? [String: Any] {
            cwd = p["cwd"] as? String; session = (p["id"] as? String) ?? session; originator = (p["originator"] as? String) ?? ""
            // A SUB-AGENT'S THREAD, NOT HIS. A guardian review or a spawned agent writes a rollout
            // of its own whose "source" is an object ({"subagent": …}) and whose thread_source is
            // "guardian_review" / "subagent"; its prompt IS the parent's tool calls and results.
            if let ts = p["thread_source"] as? String, ts != "user" { return nil }
            if let s = p["source"] as? String { origin = s } else if p["source"] != nil { return nil }
        }
        if origin == "exec" { return nil }                                                   // a program ran it; he did not ask
        // The desktop app he calls ChatGPT is com.openai.codex: same rollouts, its own name.
        let source = originator == "Codex Desktop" ? "ChatGPT desktop" : (origin == "cli" ? "Codex" : "Codex (\(origin))")
        var question: (text: String, at: Double)?; var answer: String?; var answeredAt: Double?; var done = false
        for (index, line) in lines.enumerated() {
            guard let j = json(line), let kind = j["type"] as? String, let p = j["payload"] as? [String: Any] else { continue }
            let at = (j["timestamp"] as? String).flatMap(iso) ?? 0
            if kind == "response_item", (p["type"] as? String) == "message", let role = p["role"] as? String, let content = p["content"] as? [[String: Any]] {
                var text = content.filter { ["input_text", "output_text"].contains(($0["type"] as? String) ?? "") }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if role == "user", text.contains("[Image"), withoutAttachments(text).isEmpty { text = "(a screenshot, no words)" }
                if role == "user", isHis(text) { question = (withoutAttachments(text), at); questionIndex = index; answer = nil; answeredAt = nil; done = false }
                else if role == "assistant", question != nil, !text.isEmpty { answer = text; answeredAt = at }
            } else if kind == "event_msg", question != nil {
                if (p["type"] as? String) == "task_complete" { done = true }
                if (p["type"] as? String) == "task_started" { done = false }
            }
        }
        guard let q = question else { return nil }
        let asked = prose(q.text, limit: 600)
        guard !asked.isEmpty else { return nil }
        return (Exchange(externalId: "codex:\(session):\(Int(q.at))", source: source, sessionId: session, cwd: cwd,
                        question: asked, answer: answer.map { prose($0, limit: 1500) }, askedAt: q.at, answeredAt: answeredAt, done: done && answer != nil), questionIndex)
    }

    nonisolated private static func json(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    nonisolated private static func iso(_ s: String) -> Double? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (f.date(from: s) ?? ISO8601DateFormatter().date(from: s)).map { $0.timeIntervalSince1970 * 1000 }
    }
    nonisolated private static func head(_ path: String, bytes: Int) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: bytes), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }
}

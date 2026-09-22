import Foundation

/// COWORK IS CLAUDE CODE. Claude desktop's chats keep no readable transcript on this Mac —
/// but its Cowork / local-agent sessions are Claude Code under the hood. The desktop keeps
/// one file per session at
///
///   ~/Library/Application Support/Claude/local-agent-mode-sessions/<space>/<x>/local_<id>.json
///   { sessionId: "local_<id>", cliSessionId: "<uuid>", cwd, userSelectedFolders, lastActivityAt, model, … }
///
/// and the `cliSessionId` transcript lands in ~/.claude/projects/<cwd-key>/<cliSessionId>.jsonl
/// with `entrypoint:"sdk-ts"`. `sdk-ts` on its own is NOT a signal that he asked: Conductor
/// and every other SDK host write the same entrypoint (measured on this Mac: all six sdk-ts
/// transcripts present were Conductor workspaces). So the allowance is exactly the ids this
/// index names — a desktop session is one the desktop itself wrote down.
///
/// Refreshed only when that folder changes (AnswerWatcher watches it alongside the transcript
/// roots and calls `invalidate`); never on a timer; read lazily, cached in memory.
enum DesktopSessions {
    struct Session: Equatable {
        /// The desktop's own id ("local_…") — the handle a jump back into the app will need.
        let desktopSessionId: String
        let cliSessionId: String
        let cwd: String?
        /// The folders he chose for the session; `cwd` is the session's own outputs folder.
        let folders: [String]
        let lastActivityAt: Double
    }

    /// The folder the desktop writes; a test points it elsewhere (VELOCITY_DESKTOP_SESSIONS).
    static let root: String = {
        if let override = ProcessInfo.processInfo.environment["VELOCITY_DESKTOP_SESSIONS"], !override.isEmpty { return override }
        return NSHomeDirectory() + "/Library/Application Support/Claude/local-agent-mode-sessions"
    }()

    private static let lock = NSLock()
    private static var byCLI: [String: Session]?

    static func isClaudeDesktop(_ cliSessionId: String) -> Bool { session(forCLI: cliSessionId) != nil }

    static func session(forCLI cliSessionId: String) -> Session? { index()[cliSessionId] }

    /// The desktop's own session id for a Claude Code session id, when the desktop owns it.
    static func desktopSessionId(forCLI cliSessionId: String) -> String? { session(forCLI: cliSessionId)?.desktopSessionId }

    /// The folder changed (FSEvents): forget the index; the next question re-reads it.
    static func invalidate() { lock.lock(); byCLI = nil; lock.unlock() }

    static func index() -> [String: Session] {
        lock.lock(); defer { lock.unlock() }
        if let byCLI { return byCLI }
        let loaded = load(root)
        byCLI = loaded
        return loaded
    }

    /// Every local_*.json under the root (three levels deep in practice; bounded, not recursive without limit).
    static func load(_ root: String) -> [String: Session] {
        var out: [String: Session] = [:]
        guard let e = FileManager.default.enumerator(atPath: root) else { return out }
        while let rel = e.nextObject() as? String {
            if e.level > 4 { e.skipDescendants(); continue }
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            guard let data = FileManager.default.contents(atPath: root + "/" + rel),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cli = j["cliSessionId"] as? String, !cli.isEmpty else { continue }
            let desktopId = (j["sessionId"] as? String) ?? (name as NSString).deletingPathExtension
            let s = Session(desktopSessionId: desktopId, cliSessionId: cli, cwd: j["cwd"] as? String,
                            folders: (j["userSelectedFolders"] as? [String]) ?? [], lastActivityAt: (j["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0)
            // Two desktop sessions naming one cli session: the one touched last wins.
            if let prior = out[cli], prior.lastActivityAt > s.lastActivityAt { continue }
            out[cli] = s
        }
        return out
    }
}

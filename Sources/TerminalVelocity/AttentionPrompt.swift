import CryptoKit
import Foundation

// WHAT IS IT ASKING? "[!] Action Required" in a title says an agent is waiting on him and
// nothing more; the ribbon showed the session's task and a Go button ("could this thing
// allow me to just click yes and give me enough to make a decision?"). The question is on
// the tab's screen: read it there (one Apple Event), keep only what it is asking, and send
// that with the report — bounded, secret-shaped lines refused (TranscriptLaw). A "Yes" from
// the ribbon becomes the harness's own keys typed into that exact tab, verified in front.
enum AttentionPrompt {
    /// Which harness is asking, from the tab's title ("… ◂ claude", "codex ◂ node").
    static func harness(title: String) -> String? {
        // THE PROCESS, NOT THE TASK: Terminal's title ends with the process chain ("… — codex ◂
        // node …", "… — node ◂ claude --resume"); a task named "Review Claude transcript" in
        // a Codex tab is Codex's. The last " — " segment first; the whole title only as a fallback.
        let tail = title.components(separatedBy: " — ").last?.lowercased() ?? ""
        for t in [tail, title.lowercased()] {
            if t.range(of: #"\bclaude\b"#, options: .regularExpression) != nil { return "claude" }
            if t.range(of: #"\bcodex\b"#, options: .regularExpression) != nil { return "codex" }
        }
        return nil
    }

    /// The question on screen: the last lines of the tab, decoration and terminal chrome
    /// dropped, secret-shaped lines refused, at most `maxLines` and 900 characters.
    static func extract(_ contents: String, maxLines: Int = 14) -> String? {
        let raw = contents.replacingOccurrences(of: "\r\n?", with: "\n", options: .regularExpression).components(separatedBy: "\n")
        var lines: [String] = []
        for line in raw.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isDecoration(t) || isChrome(t) { continue }
            guard let clean = TranscriptLaw.line(t) else { continue }   // a secret-shaped line is refused
            lines.insert(clean, at: 0)
            if lines.count >= maxLines { break }
        }
        // The block starts at the last "question opener" if one is near the end; else the tail.
        if let i = lines.lastIndex(where: isOpener), lines.count - i <= maxLines { lines = Array(lines[i...]) }
        let text = String(lines.joined(separator: "\n").prefix(900)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The keys that mean yes, read from the DIALOG ITSELF — the harness title only breaks a
    /// tie. Both Claude Code and Codex highlight the Yes option and take Return ("Press enter
    /// to confirm", "❯ 1. Yes"): Return is the reliable answer. A bare y/n prompt with no
    /// highlighted default and a "(y)" hotkey takes "y".
    static func yesKeys(screen: String, harness: String?) -> (text: String, enter: Bool) {
        let s = screen.lowercased()
        // RETURN CONFIRMS THE HIGHLIGHTED YES. Both Claude Code ("❯ 1. Yes") and Codex ("› 1.
        // Yes, proceed (y)" + "Press enter to confirm") select their Yes with Return — that is
        // what he does by hand. A letter like "y" typed a literal character that shifted the
        // screen without approving (the receipt then wrongly read as cleared, and he still had
        // to hit Enter). Return via System Events (not the synthetic CGEvent that never landed)
        // is the reliable confirm. Only a bare y/n prompt with NO "enter to confirm" and NO
        // highlighted option takes the letter.
        let hasEnterConfirm = s.contains("press enter") || s.contains("enter to confirm")
        let hasHighlight = s.range(of: #"[❯›▶]\s*\d"#, options: .regularExpression) != nil
        if hasEnterConfirm || hasHighlight { return ("", true) }
        if s.range(of: #"\[y/n\]|\by/n\b|yes/no|\(y\)"#, options: .regularExpression) != nil { return ("y", false) }
        return ("", true)
    }
    /// Is the tab ACTUALLY waiting on a keypress? The "[ ! ] Action Required" title marker also
    /// lights up when a harness FINISHES a turn and sits idle, and on a plain progress note —
    /// neither is a question ("i keep getting false alarms on need input… that needs-input flag
    /// was a false alarm, only a progress note while work continued, not a question"). A real
    /// approval/choice dialog shows a highlighted option, an "enter to confirm", a y/n prompt,
    /// or a direct "do you want / would you like / allow / wants to" ask. Without any of those
    /// there is nothing to say Yes to — report no prompt, and the ribbon drops the Yes button.
    /// Run this on the EXTRACTED tail, not the raw buffer, so a stale answered dialog scrolled
    /// up the screen cannot re-arm it.
    static func pending(_ question: String) -> Bool {
        let s = question.lowercased()
        if s.contains("press enter") || s.contains("enter to confirm") { return true }
        if s.range(of: #"[❯›▶]\s*\d[.)]"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"\[y/n\]|\by/n\b|yes/no|\(y\)"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?:^|\n)\s*(?:do you want|would you like|allow |approve\b|permission\b)"#, options: .regularExpression) != nil { return true }
        if s.contains(" wants to ") || s.contains("shall i ") { return true }
        return false
    }

    /// THE QUESTION'S IDENTITY. "Yes" is bound to the exact prompt he saw: Julia sends this
    /// digest with the approve, Velocity re-reads the screen and refuses if it differs. The
    /// server computes the SAME function in TS — keep them identical:
    ///   s.split("\n").map(l => l.trim()).filter(l => l.length > 0).join("\n") → sha256 → lowercase hex
    static func normalized(_ prompt: String) -> String {
        prompt.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    static func digest(_ prompt: String) -> String {
        SHA256.hash(data: Data(normalized(prompt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What a readable screen says about the agent: a real dialog → needs_input; the harness's
    /// own "esc to interrupt" / "Working (" line → working; otherwise the turn is over → idle.
    /// Nil when there is nothing to read (the title is then the only evidence).
    static func screenState(_ contents: String?) -> String? {
        guard let contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let tail = extract(contents), pending(tail) { return "needs_input" }
        let last = String(contents.suffix(800)).lowercased()
        if last.contains("esc to interrupt") || last.range(of: #"(?:^|\n)\s*[•◦·]?\s*working\s*\("#, options: .regularExpression) != nil { return "working" }
        return "idle"
    }

    /// The line whose disappearance proves the dialog was answered — the choice prompt itself.
    static func gateLine(_ question: String) -> String? {
        question.components(separatedBy: "\n").last { l in
            let t = l.lowercased()
            return t.contains("proceed") || t.contains("confirm") || t.contains("allow") || t.contains("would you like") || t.range(of: #"[❯›▶]\s*\d\."#, options: .regularExpression) != nil || t.contains("do you want")
        }
    }

    private static func isDecoration(_ t: String) -> Bool {
        t.allSatisfy { "─━═-=│┃║╭╮╰╯┌┐└┘├┤┬┴┼ ·".contains($0) } && t.count >= 3
    }
    private static func isChrome(_ t: String) -> Bool {
        t.hasPrefix("⏵") || t.hasPrefix("? for shortcuts") || t.hasPrefix("esc to") || t.contains("shift+tab to cycle") || t.hasPrefix("❯ ") && t.count <= 2
    }
    private static func isOpener(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.hasPrefix("do you want") || l.hasPrefix("allow ") || l.hasPrefix("would you like") || l.contains(" wants to ") || l.hasPrefix("approve") || l.hasPrefix("permission") || l.hasPrefix("run this command") || l.hasPrefix("bash command") || l.hasPrefix("edit file") || l.hasPrefix("write file") || l.hasPrefix("read file") || l.hasPrefix("fetch") || l.hasPrefix("web search") || l.hasPrefix("create file")
    }
}


/// "YES" IS BOUND TO THE EXACT PROMPT HE SAW. The approve act used to press Return on whatever
/// dialog was on screen — and press again if it lingered, answering a dialog he never saw.
/// Now: the screen's question must match the digest he approved (or, from an older Julia that
/// sends none, the prompt Velocity itself last reported for that tab); the key goes in ONCE;
/// what follows is read and said honestly, never answered.
enum ApproveGate {
    enum Before: Equatable { case proceed(digest: String), refuse(ActReceipt) }
    enum After: Equatable { case cleared, stillAsking, newAsk(digest: String) }

    static func before(screen: String?, digest sent: String?, lastReported: String?) -> Before {
        guard let screen, let asking = AttentionPrompt.extract(screen), AttentionPrompt.pending(asking) else {
            return .refuse(.failed(class: "stale", why: "Nothing is being asked on that tab any more."))
        }
        let now = AttentionPrompt.digest(asking)
        let changed = ActReceipt.failed(class: "changed", why: "The question on screen changed — open it to decide.")
        if let sent = sent?.trimmingCharacters(in: .whitespaces).lowercased(), !sent.isEmpty {
            return sent == now ? .proceed(digest: now) : .refuse(changed)
        }
        // An older Julia sent no digest: never blind — only the prompt this Mac reported.
        guard let lastReported, AttentionPrompt.digest(lastReported) == now else { return .refuse(changed) }
        return .proceed(digest: now)
    }

    /// One read after the key went in.
    static func after(screen: String?, approved: String) -> After? {
        guard let screen else { return nil }   // unreadable: no evidence either way
        guard let asking = AttentionPrompt.extract(screen), AttentionPrompt.pending(asking) else { return .cleared }
        let now = AttentionPrompt.digest(asking)
        return now == approved ? .stillAsking : .newAsk(digest: now)
    }

    /// The receipt for what was seen after ONE press (nil = never saw it settle).
    static func receipt(_ outcome: After?, digest: String, tty: String, keys: String) -> ActReceipt {
        switch outcome {
        case .cleared:
            return .verified(method: "prompt-cleared", observed: "approved \(digest) on \(tty) with \(keys); the question left the screen")
        case .newAsk(let next):
            return .verified(method: "prompt-cleared", observed: "approved \(digest) on \(tty) with \(keys); a NEW question is on screen now (\(next)) — not answered")
        case .stillAsking, nil:
            return .failed(class: "uncertain", why: "Sent yes once to \(tty) (\(digest)) but the same question is still on screen — open it and answer there.")
        }
    }
}

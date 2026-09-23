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
        if s.contains("press enter to confirm") || s.contains("enter to confirm") || s.range(of: #"[❯›▶]\s*1\.\s*yes"#, options: .regularExpression) != nil { return ("", true) }
        if s.range(of: #"\(y\)|\[y/n\]|\by/n\b|yes/no"#, options: .regularExpression) != nil && s.range(of: #"[❯›▶]\s*1\."#, options: .regularExpression) == nil { return ("y", true) }
        return ("", true)   // default: the highlighted Yes + Return
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

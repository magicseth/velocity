import Foundation

struct AttentionPresentation {
    let project: String
    let task: String

    init(_ entry: WindowEntry) {
        var task = entry.agentTaskTitle ?? "Agent needs input"
        // The agent names its own project ("task | project"). Terminal chrome may
        // prepend anything — user, host, cwd — so that prefix is only a fallback.
        let parts = task.components(separatedBy: " | ")
        var project: String?
        if parts.count >= 2, let tail = parts.last?.trimmingCharacters(in: .whitespaces), !tail.isEmpty, tail.count <= 80 {
            project = tail
            task = parts.dropLast().joined(separator: " | ")
        }
        if project == nil {
            let prefix = entry.title.components(separatedBy: " — ").first ?? ""
            if !prefix.isEmpty, !prefix.contains("Action Required"), !prefix.contains("✳"), entry.title.contains(" — ") {
                project = String((prefix as NSString).lastPathComponent.prefix(80))
            }
        }
        self.project = project ?? entry.appName
        self.task = String(task.prefix(180))
    }

    // This is an observed excerpt, not a claim that an arbitrary '?' in terminal
    // history is the agent's current question. No model or network is involved.
    static func excerpt(_ text: String) -> String? {
        let unavailable = ["No accessible terminal text", "This tab is in the background", "This terminal does not expose"]
        guard !unavailable.contains(where: text.hasPrefix) else { return nil }
        let clean = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let lines = clean.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return String(lines.suffix(5).joined(separator: "\n").prefix(500))
    }
}

import Foundation

struct AttentionPresentation {
    let project: String
    let task: String

    init(_ entry: WindowEntry) {
        let prefix = entry.title.components(separatedBy: " — ").first ?? ""
        if !prefix.isEmpty, !prefix.contains("Action Required"), !prefix.contains("✳"),
           entry.title.contains(" — ") {
            project = String((prefix as NSString).lastPathComponent.prefix(80))
        } else { project = entry.appName }
        var task = entry.agentTaskTitle ?? "Agent needs input"
        let suffix = " | " + project
        if task.hasSuffix(suffix) { task.removeLast(suffix.count) }
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

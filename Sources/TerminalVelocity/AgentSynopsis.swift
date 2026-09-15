import Foundation

extension WindowEntry {
    var displayTitle: String {
        #if VELOCITY_EXPERIMENTAL
        return agentSynopsis ?? title
        #else
        return title
        #endif
    }

    #if VELOCITY_EXPERIMENTAL
    var agentSynopsis: String? { agentTaskTitle }
    #endif

    /// Shared by presentation and duplicate detection in both build variants.
    /// Derived only from agent title markers, never from generated summaries.
    var agentTaskTitle: String? {
        guard terminal, attention != .none else { return nil }
        var task = title
        if let marker = task.range(of: #"\[\s*[!.]\s*\]\s+Action Required\s*\|?\s*|[✳◐◑]\s+"#, options: .regularExpression) {
            task = String(task[marker.upperBound...])
        }
        task = task.components(separatedBy: " ◂ ")[0]
            .replacingOccurrences(of: #"\s+—\s+(?:node\b.*|claude\b.*|codex\b.*|\d+[×x]\d+)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return task.isEmpty ? nil : task
    }
}

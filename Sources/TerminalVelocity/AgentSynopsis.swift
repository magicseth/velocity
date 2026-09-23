import Foundation

extension WindowEntry {
    var displayTitle: String {
        #if VELOCITY_EXPERIMENTAL
        guard let synopsis = agentSynopsis else { return title }
        // Keep the identifying folder/prefix that search matches, even when
        // the agent's status and process suffix are simplified for display.
        if let marker = title.range(of: #"\[\s*[!.]\s*\]\s+Action Required\s*\|?\s*|[✳◐◑]\s+"#, options: .regularExpression) {
            let prefix = String(title[..<marker.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+[—–-]$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix + " — " + synopsis }
        }
        return synopsis
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

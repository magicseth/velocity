import Foundation

enum AgentAttention: String {
    case none, needsInput, idle, working
    var label: String {
        switch self {
        case .none: return ""
        case .needsInput: return "Needs input"
        case .idle: return "Ready / idle"
        case .working: return "Working"
        }
    }
    var needsAttention: Bool { self == .needsInput }
    static func detect(title: String, terminal: Bool) -> Self {
        guard terminal else { return .none }
        // Match the status prefix, not a task discussing approvals.
        if title.range(of: #"(?:^|—\s*|\|\s*)\[\s*[!.]\s*\]\s+Action Required(?:\s*\||\s*—|$)"#, options: .regularExpression) != nil { return .needsInput }
        // CODEX: its title leads with a braille spinner while it works ("⠸ Build WS0 spine |
        // amusebot") and drops it when the turn ends. The process chain says it is Codex; a
        // braille spinner alone (a tab title with no chain) is Codex's too — nothing else uses it.
        let spinner = title.range(of: #"(?:^|—\s*)[\u{2801}-\u{28FF}]\s"#, options: .regularExpression) != nil
        let codex = processChain(title).map { chain in chain.range(of: #"(?i)\bcodex\b"#, options: .regularExpression) != nil
            && chain.range(of: #"(?i)\bclaude\b"#, options: .regularExpression) == nil } ?? false
        if codex || spinner { return spinner ? .working : .idle }
        let claude = title.range(of: #"(?i)\bclaude(?:\s|$)"#, options: .regularExpression) != nil
        guard claude else { return .none }
        if title.range(of: #"(?:^|—\s*)[◐◑]\s"#, options: .regularExpression) != nil { return .working }
        if title.range(of: #"(?:^|—\s*)✳\s"#, options: .regularExpression) != nil { return .idle }
        return .none
    }
    /// Terminal's title segment naming the running process ("codex ◂ node …", "node ◂ claude"):
    /// the one with "◂", else the last that isn't the "120×30" size. Nil for a bare title.
    static func processChain(_ title: String) -> String? {
        let parts = title.components(separatedBy: " — ")
        guard parts.count > 1 else { return nil }
        if let chain = parts.last(where: { $0.contains("◂") }) { return chain }
        return parts.last(where: { $0.range(of: #"^\d+×\d+$"#, options: .regularExpression) == nil })
    }
}

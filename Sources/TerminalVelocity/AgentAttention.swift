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
        let claude = title.range(of: #"(?i)\bclaude(?:\s|$)"#, options: .regularExpression) != nil
        guard claude else { return .none }
        if title.range(of: #"(?:^|—\s*)[◐◑]\s"#, options: .regularExpression) != nil { return .working }
        if title.range(of: #"(?:^|—\s*)✳\s"#, options: .regularExpression) != nil { return .idle }
        return .none
    }
}

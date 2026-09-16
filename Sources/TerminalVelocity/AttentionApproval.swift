import AppKit
import ApplicationServices
import CryptoKit

struct AttentionApproval {
    enum Reply: Equatable { case yesKey, yesAndReturn }
    let digest: String
    let reply: Reply
    let created: Date
    let prompt: String

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func parse(_ text: String, now: Date = Date()) -> Self? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        // Only an explicit current yes/no input, not prose saying “yes”.
        if last.range(of: #"(?i)\?\s*\[(?:y/n|yes/no)\]\s*:?\s*$"#, options: .regularExpression) != nil,
           last.count <= 500 {
            return Self(digest: hash(text), reply: .yesAndReturn, created: now, prompt: last)
        }
        // Codex's one-time approval menu advertises a dedicated y shortcut.
        // Do not interpret arbitrary numbered menus or “always allow” options.
        let tail = Array(lines.suffix(12))
        guard tail.contains(where: { $0.range(of: #"^[›❯>]?\s*1\. Yes, proceed \(y\)$"#, options: .regularExpression) != nil }),
              tail.contains(where: { $0.range(of: #"^[›❯>]?\s*[23]\. No, and tell Codex what to do differently \(esc\)$"#, options: .regularExpression) != nil }),
              last.lowercased().contains("esc"), last.lowercased().contains("cancel") else { return nil }
        let prompt = tail.joined(separator: "\n")
        guard prompt.count <= 1200 else { return nil }
        return Self(digest: hash(text), reply: .yesKey, created: now, prompt: prompt)
    }
    func matches(_ text: String, now: Date = Date()) -> Bool {
        now >= created && now.timeIntervalSince(created) <= 120 && Self.hash(text) == digest && Self.parse(text)?.reply == reply
    }
}

@MainActor enum AttentionAnswer {
    static func send(_ approval: AttentionApproval, to entry: WindowEntry) -> Bool {
        guard let window = entry.element,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid,
              let focused = Accessibility.element(AXUIElementCreateApplication(entry.pid), kAXFocusedWindowAttribute),
              CFEqual(window, focused),
              entry.tab.map({ WindowCatalog.tabIsSelected($0) == true }) ?? true,
              approval.matches(WindowCatalog.promptPreview(entry)) else { return false }
        // Post to the verified process, never to whichever app gains global focus.
        // The one-shot ticket has already been consumed. No retries on uncertainty.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 16, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 16, keyDown: false) else { return false }
        down.flags = []; up.flags = []
        var yes: UniChar = 121
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &yes)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &yes)
        down.postToPid(entry.pid); up.postToPid(entry.pid)
        if approval.reply == .yesAndReturn {
            guard let enter = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let release = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return false }
            enter.flags = []; release.flags = []
            enter.postToPid(entry.pid); release.postToPid(entry.pid)
        }
        return true
    }
}

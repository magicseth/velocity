import AppKit
import ApplicationServices
import CryptoKit

struct WindowEntry: Identifiable, @unchecked Sendable {
    let id: String
    let pid: pid_t
    let appName: String
    var title: String
    let icon: NSImage?
    var element: AXUIElement?
    let minimized: Bool
    let hidden: Bool
    let terminal: Bool
    var tab: AXUIElement? = nil
    var browserTab: BrowserTab? = nil
    var audio: AudioBadge = .none
    var browser: Bool = false
    var documentPath: String? = nil
    var launchURL: URL? = nil
    var browserProfile: String? = nil
    var browserProfileIcon: NSImage? = nil
    var chatProject: ChatProject? = nil
    var conversation: ConversationDestination? = nil
    // A destination can represent its owning window even when their labels differ.
    var representedWindowTitle: String? = nil
    var browserPinned = false
    var closedTab: ClosedTab? = nil
    var cachedTerminal: CachedTerminal? = nil
    var documentFolder: String {
        guard let documentPath else { return "" }
        return terminal ? documentPath : (documentPath as NSString).deletingLastPathComponent
    }
    var searchText: String {
        [title, representedWindowTitle, browserTab?.url ?? closedTab?.url, documentPath, browserProfile, chatProject?.mode].compactMap { $0 }.joined(separator: " ")
    }
    var groupFingerprint: String {
        let normalized = title.replacingOccurrences(of: #"\[\s*[!.]\s*\] Action Required\s*\|?\s*|[✳◐◑]\s*"#, with: "", options: .regularExpression)
        let identity = appName + ":" + (documentPath ?? "") + ":" + normalized
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var attentionTaskTitle: String {
        // Window titles prepend a folder name; tab titles may prepend its full path.
        if let range = title.range(of: "Action Required") {
            return String(title[range.lowerBound...]).components(separatedBy: " ◂ ")[0]
                .replacingOccurrences(of: #"\s+—\s+\d+[×x]\d+\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
    var attention: AgentAttention { AgentAttention.detect(title: title, terminal: terminal && cachedTerminal == nil) }
    var windowKey: String? {
        chatProject == nil && conversation == nil ? element.map { "\(pid):\(CFHash($0))" } : nil
    }
    var memoryKey: String {
        let identity: String
        if let conversation { identity = conversation.key }
        else if let chatProject { identity = appName + ":project:" + chatProject.key }
        else if let launchURL { identity = "launch:" + launchURL.path }
        else if let browserTab { identity = browserTab.browserID + ":" + browserTab.url }
        else if let documentPath { identity = appName + ":" + documentPath }
        else if terminal { identity = appName + ":" + title.components(separatedBy: " — ")[0] }
        else { identity = appName + ":" + WindowCatalog.cleanTabTitle(title) }
        // Remember only user-selected identifiers, not a browsing log.
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var isTab: Bool { tab != nil || browserTab != nil || closedTab != nil || cachedTerminal?.tabTitle != nil }
    var subtitle: String {
        if cachedTerminal != nil { return appName + " · Cached session · checking availability…" }
        if let closedTab {
            let age = RelativeDateTimeFormatter().localizedString(for: closedTab.closed, relativeTo: Date())
            return [appName, "Recently closed " + age, browserProfile, URL(string: closedTab.url)?.host].compactMap { $0 }.joined(separator: " · ")
        }
        if let conversation { return appName + (conversation.appID == Conversations.slackID ? " · Channel / DM" : " · Conversation") }
        if let chatProject { return appName + (chatProject.mode == "Workspace" ? " · Workspace" : " · Project · " + chatProject.mode) }
        if launchURL != nil { return "Launch app" }
        var parts = [appName, isTab ? "Tab" : element == nil ? "Application" : "Window"]
        if let browserProfile { parts.append(browserProfile) }
        if let address = browserTab?.url, let host = URL(string: address)?.host { parts.append(host) }
        if !documentFolder.isEmpty { parts.append((documentFolder as NSString).abbreviatingWithTildeInPath) }
        if minimized { parts.append("Minimized") }
        if hidden { parts.append("Hidden") }
        return parts.joined(separator: " · ")
    }
}


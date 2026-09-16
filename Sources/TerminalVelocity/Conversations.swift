import AppKit
import ApplicationServices

struct ConversationDestination: Equatable, Sendable {
    let appID: String
    let name: String
    let scope: String
    var key: String { appID + ":" + scope + ":" + name }
}

/// Reads navigation only. Never traverses transcripts or message composers.
enum Conversations {
    static let messagesID = "com.apple.MobileSMS"
    static let slackID = "com.tinyspeck.slackmacgap"
    static func messagesName(_ description: String) -> String? {
        // Messages combines recipient, status, preview and date in AXDescription.
        // Keep only the recipient; never retain the preview.
        let name = description.components(separatedBy: ", ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
    static func current(window: AXUIElement, appID: String) -> [(ConversationDestination, AXUIElement)] {
        guard [messagesID, slackID].contains(appID) else { return [] }
        let deadline = Date().addingTimeInterval(1)
        var visited = Set<CFHashCode>()
        var sidebar: AXUIElement?
        var scope = ""
        func find(_ node: AXUIElement, depth: Int) {
            guard sidebar == nil, depth < 20, visited.count < 1500, Date() < deadline,
                  visited.insert(CFHash(node)).inserted else { return }
            AXUIElementSetMessagingTimeout(node, 0.05)
            let role = Accessibility.string(node, kAXRoleAttribute)
            let identifier = Accessibility.string(node, kAXIdentifierAttribute)
            if appID == messagesID && identifier == "ConversationList" { sidebar = node; return }
            if appID == slackID && role == kAXOutlineRole && Accessibility.label(node, includingValue: true) == "Channels and direct messages" { sidebar = node; return }
            if role == "AXWebArea", let url = Accessibility.attribute(node, kAXURLAttribute) {
                let raw = (url as? URL)?.absoluteString ?? (url as? String ?? "")
                scope = slackScope(raw) ?? ""
            }
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, "AXList"].contains(role) ||
                ["TranscriptCollectionView", "MessageEntryView"].contains(identifier) { return }
            for child in Accessibility.children(node) { find(child, depth: depth + 1) }
        }
        find(window, depth: 0)
        guard let sidebar, appID != slackID || !scope.isEmpty else { return [] }
        var result: [(ConversationDestination, AXUIElement)] = []
        if appID == messagesID {
            for node in Accessibility.children(sidebar) {
                if let name = messagesName(Accessibility.string(node, kAXDescriptionAttribute)) {
                    result.append((.init(appID: appID, name: name, scope: ""), node))
                }
            }
        } else {
            func texts(_ node: AXUIElement, depth: Int) -> [String] {
                guard depth < 5, Date() < deadline else { return [] }
                if Accessibility.string(node, kAXRoleAttribute) == kAXStaticTextRole { return [Accessibility.label(node, includingValue: true)] }
                return Accessibility.children(node).flatMap { texts($0, depth: depth + 1) }
            }
            func rows(_ node: AXUIElement, depth: Int) {
                guard depth < 12, Date() < deadline else { return }
                let nodes = Accessibility.children(node)
                if Accessibility.string(node, kAXRoleAttribute) == kAXRowRole {
                    let names = texts(node, depth: 0).filter { !$0.isEmpty }
                    if names.count == 1 {
                        result.append((.init(appID: appID, name: names[0], scope: scope), node))
                        return
                    }
                }
                for child in nodes { rows(child, depth: depth + 1) }
            }
            rows(sidebar, depth: 0)
        }
        // Ambiguous names cannot safely identify a conversation. Omit rather than guess.
        let counts = Dictionary(grouping: result, by: { $0.0.key }).mapValues(\.count)
        return result.filter { counts[$0.0.key] == 1 }
    }
    static func slackScope(_ raw: String) -> String? {
        let url = URL(string: raw.contains("://") ? raw : "https://" + raw)
        guard let url, url.host == "app.slack.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "client", parts[1].first == "T",
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return String(parts[1])
    }
    static func scan(window: AXUIElement, app: NSRunningApplication) -> [WindowEntry] {
        guard let appID = app.bundleIdentifier else { return [] }
        let rows = current(window: window, appID: appID)
        guard !rows.isEmpty else { return [] }
        // Read the Messages header, not the transcript. Pinned row selection can lag
        // behind navigation, so prefer the actual conversation header when available.
        func header(_ node: AXUIElement, depth: Int) -> String? {
            guard depth < 5 else { return nil }
            if Accessibility.string(node, kAXIdentifierAttribute) == "ConversationTitle" {
                return messagesName(Accessibility.label(node, includingValue: true))
            }
            if ["ConversationList", "TranscriptCollectionView", "MessageEntryView"].contains(Accessibility.string(node, kAXIdentifierAttribute)) { return nil }
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(Accessibility.string(node, kAXRoleAttribute)) { return nil }
            for child in Accessibility.children(node) {
                if let found = header(child, depth: depth + 1) { return found }
            }
            return nil
        }
        let active: [(ConversationDestination, AXUIElement)]
        if appID == messagesID, let name = header(window, depth: 0) {
            active = rows.filter { $0.0.name == name }
        } else {
            active = rows.filter { Accessibility.attribute($0.1, kAXSelectedAttribute) as? Bool == true }
        }
        let selectedKey = active.count == 1 ? active[0].0.key : nil
        let windowTitle = Accessibility.string(window, kAXTitleAttribute)
        return rows.map { destination, _ in
            WindowEntry(id: "\(app.processIdentifier):conversation:\(CFHash(window)):\(destination.key)",
                        pid: app.processIdentifier, appName: app.localizedName ?? "", title: destination.name,
                        icon: app.icon, element: window,
                        minimized: Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                        hidden: app.isHidden, terminal: false, conversation: destination,
                        representedWindowTitle: destination.key == selectedKey && !windowTitle.isEmpty ? windowTitle : nil)
        }
    }
    @MainActor static func select(_ destination: ConversationDestination, window: AXUIElement) -> Bool {
        let matches = current(window: window, appID: destination.appID).filter { $0.0 == destination }
        guard matches.count == 1 else { return false }
        let node = matches[0].1
        // Sidebar rows can report Press success without navigating. Click the freshly resolved row,
        // only while its owning app is foreground and its bounds are on screen.
        var pid: pid_t = 0
        AXUIElementGetPid(node, &pid)
        // Slack's row bounds may cover a virtualized region rather than its label.
        // Aim at the exact visible name, while retaining the row for hit testing.
        func nameLabel(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 5 else { return nil }
            if Accessibility.string(element, kAXRoleAttribute) == kAXStaticTextRole,
               Accessibility.label(element, includingValue: true) == destination.name { return element }
            for child in Accessibility.children(element) {
                if let label = nameLabel(child, depth: depth + 1) { return label }
            }
            return nil
        }
        let clickTarget = destination.appID == slackID ? nameLabel(node, depth: 0) ?? node : node
        if destination.appID == slackID,
           AXUIElementPerformAction(clickTarget, kAXPressAction as CFString) == .success { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let frame = Accessibility.frame(clickTarget) else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // Hit-test to avoid clicking content covering a stale/offscreen sidebar row.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y), &hit) == .success,
              var ancestor = hit else { return false }
        var belongs = false
        for _ in 0..<8 {
            if CFEqual(ancestor, node) { belongs = true; break }
            guard let parent = Accessibility.element(ancestor, kAXParentAttribute) else { break }
            ancestor = parent
        }
        guard belongs else { return false }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }
}

import AppKit
import ApplicationServices
import CryptoKit

struct ChatProject: Codable, Sendable {
    let name: String
    let mode: String
    let url: String?
    var key: String { mode + ":" + (url ?? name) }
}

enum ChatProjects {
    static let claudeID = "com.anthropic.claudefordesktop"
    private static func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = WindowCatalog.attribute(element, key) as? String, !value.isEmpty { return value }
        }
        return ""
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        WindowCatalog.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func role(_ element: AXUIElement) -> String {
        WindowCatalog.attribute(element, kAXRoleAttribute) as? String ?? ""
    }
    static func projectName(_ label: String) -> String? {
        for prefix in ["Toggle chats for ", "Toggle sessions for ", "New session in "] where label.hasPrefix(prefix) {
            let name = String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }
    private static func nodes(_ window: AXUIElement) -> [(AXUIElement, Bool)] {
        var found: [(AXUIElement, Bool)] = []
        var seen: Set<CFHashCode> = []
        let deadline = Date().addingTimeInterval(2)
        func walk(_ element: AXUIElement, depth: Int, inSidebar: Bool) {
            guard depth < 24, found.count < 2000, Date() < deadline, seen.insert(CFHash(element)).inserted else { return }
            AXUIElementSetMessagingTimeout(element, 0.05)
            let kind = role(element)
            // Never collect prompt fields or conversation text.
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(kind) { return }
            let sidebar = inSidebar || label(element) == "Sidebar"
            found.append((element, sidebar))
            for child in children(element) { walk(child, depth: depth + 1, inSidebar: sidebar) }
        }
        walk(window, depth: 0, inSidebar: false)
        return found
    }
    private static func current(_ window: AXUIElement) -> [(ChatProject, AXUIElement)] {
        let tree = nodes(window)
        let code = tree.contains { node, sidebar in
            sidebar && label(node) == "Code" && (WindowCatalog.attribute(node, kAXValueAttribute) as? NSNumber)?.boolValue == true
        }
        var projects: [(ChatProject, AXUIElement)] = []
        for (node, sidebar) in tree {
            if role(node) == "AXLink" {
                let raw = WindowCatalog.attribute(node, kAXURLAttribute)
                let url = (raw as? URL)?.absoluteString ?? raw as? String ?? ""
                if isProjectURL(url), !label(node).isEmpty {
                    projects.append((ChatProject(name: label(node), mode: "Chat / Cowork", url: url), node))
                }
            }
            guard sidebar, role(node) == kAXButtonRole else { continue }
            let text = label(node)
            if code, text.hasPrefix("New session in "), let name = projectName(text),
               let parent = WindowCatalog.attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                let parentElement = unsafeBitCast(parent, to: AXUIElement.self)
                if let header = children(parentElement).first(where: { label($0) == name && role($0) == kAXButtonRole }) {
                    projects.append((ChatProject(name: name, mode: "Code", url: nil), header))
                }
            } else if !code, let name = projectName(text), !text.hasPrefix("New session in ") {
                // Inner toggle has the exact name; the outer row opens the project.
                let nestedToggle = children(node).contains { projectName(label($0)) != nil }
                if !nestedToggle, let parent = WindowCatalog.attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    let parentElement = unsafeBitCast(parent, to: AXUIElement.self)
                    projects.append((ChatProject(name: name, mode: "Chat / Cowork", url: nil), role(parentElement) == kAXButtonRole ? parentElement : node))
                }
            }
        }
        return projects
    }
    static func isProjectURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw.hasPrefix("http") ? raw : "https://" + raw), url.host == "claude.ai" else { return false }
        return ["/cowork/project/", "/project/", "/space/"].contains { url.path.hasPrefix($0) && url.path.count > $0.count }
    }
    static func scan(window: AXUIElement, app: NSRunningApplication) -> [WindowEntry] {
        guard app.bundleIdentifier == claudeID else { return [] }
        let observed = current(window).map(\.0)
        var cached = UserDefaults.standard.data(forKey: "claudeProjectIndex").flatMap { try? JSONDecoder().decode([ChatProject].self, from: $0) } ?? []
        for project in observed {
            if let index = cached.firstIndex(where: { $0.mode == project.mode && (project.url != nil && $0.url != nil ? $0.url == project.url : $0.name == project.name) }) {
                if project.url != nil || cached[index].url == nil { cached[index] = project }
            } else { cached.append(project) }
        }
        cached = Array(cached.suffix(500))
        if let data = try? JSONEncoder().encode(cached) { UserDefaults.standard.set(data, forKey: "claudeProjectIndex") }
        return cached.map { project in
            let digest = SHA256.hash(data: Data(project.key.utf8)).map { String(format: "%02x", $0) }.joined()
            return WindowEntry(id: "\(app.processIdentifier):project:\(digest)", pid: app.processIdentifier,
                appName: app.localizedName ?? "Claude", title: project.name, icon: app.icon, element: window,
                minimized: false, hidden: app.isHidden, terminal: false, chatProject: project)
        }
    }
    @MainActor static func select(_ project: ChatProject, window: AXUIElement) async -> Bool {
        func find() -> AXUIElement? {
            let matches = current(window).filter { $0.0.mode == project.mode && ($0.0.url == project.url && project.url != nil || $0.0.name == project.name) }
            return matches.count == 1 ? matches[0].1 : matches.first(where: { $0.0.url == project.url && project.url != nil })?.1
        }
        let mode = project.mode == "Code" ? "Code" : "Chat and Cowork"
        if let selector = nodes(window).first(where: { $0.1 && label($0.0) == mode && role($0.0) == kAXRadioButtonRole })?.0,
           (WindowCatalog.attribute(selector, kAXValueAttribute) as? NSNumber)?.boolValue != true {
            guard AXUIElementPerformAction(selector, kAXPressAction as CFString) == .success else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let target = find() {
            if project.mode == "Code" {
                // Code projects are sidebar groups, not project-detail pages.
                // Reveal the group without collapsing it or starting a new session.
                if (WindowCatalog.attribute(target, kAXExpandedAttribute) as? NSNumber)?.boolValue == false {
                    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else { return false }
                }
                AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
                return true
            }
            return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
        }
        if project.mode != "Code", let all = nodes(window).first(where: { $0.1 && label($0.0) == "All projects" })?.0 {
            guard AXUIElementPerformAction(all, kAXPressAction as CFString) == .success else { return false }
            try? await Task.sleep(for: .milliseconds(350))
            if let target = find() { return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success }
        }
        return false
    }
}

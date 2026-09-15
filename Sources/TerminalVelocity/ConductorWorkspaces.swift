import AppKit
import ApplicationServices

/// Conductor's native sidebar exposes stable workspace routes through Accessibility.
/// Read navigation links only; never inspect chat messages or terminal contents.
enum ConductorWorkspaces {
    static let bundleID = "com.conductor.app"
    static func workspaceRoute(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme == "tauri", url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[0] == "repository", parts[2] == "workspace",
              UUID(uuidString: String(parts[1])) != nil, UUID(uuidString: String(parts[3])) != nil else { return nil }
        return url.absoluteString
    }
    static func workspaceName(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+[+−-](?:[\d.,]+[kKmM]?|✱+)(?:\s+[+−-](?:[\d.,]+[kKmM]?|✱+))*\s*$"#,
                                with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        WindowCatalog.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func label(_ node: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { WindowCatalog.attribute(node, $0) as? String }
            .first(where: { !$0.isEmpty }) ?? ""
    }
    static func current(_ window: AXUIElement) -> [(ChatProject, AXUIElement)] {
        var result: [(ChatProject, AXUIElement)] = []
        var seen: Set<CFHashCode> = []
        var routes: Set<String> = []
        let deadline = Date().addingTimeInterval(2)
        func walk(_ node: AXUIElement, depth: Int, inSidebar: Bool) {
            guard depth < 24, seen.count < 3000, Date() < deadline, seen.insert(CFHash(node)).inserted else { return }
            AXUIElementSetMessagingTimeout(node, 0.05)
            let role = WindowCatalog.attribute(node, kAXRoleAttribute) as? String ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(role) { return }
            if role == "AXLink" {
                guard inSidebar else { return }
                let value = WindowCatalog.attribute(node, kAXURLAttribute)
                let raw = (value as? URL)?.absoluteString ?? value as? String ?? ""
                let name = workspaceName(label(node))
                if let route = workspaceRoute(raw), !name.isEmpty, routes.insert(route).inserted {
                    result.append((ChatProject(name: name, mode: "Workspace", url: route), node))
                }
                return
            }
            let descendants = children(node)
            let sidebar = inSidebar
            for child in descendants { walk(child, depth: depth + 1, inSidebar: sidebar) }
        }
        func findSidebar(_ node: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 12, Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.05)
            let kind = WindowCatalog.attribute(node, kAXRoleAttribute) as? String ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, "AXLink", kAXButtonRole].contains(kind) { return nil }
            let nodes = children(node)
            if nodes.contains(where: {
                (WindowCatalog.attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole && label($0) == "Toggle left sidebar"
            }) { return node }
            for child in nodes {
                if let found = findSidebar(child, depth: depth + 1) { return found }
            }
            return nil
        }
        if let sidebar = findSidebar(window, depth: 0) { walk(sidebar, depth: 0, inSidebar: true) }
        return result
    }
    static func scan(window: AXUIElement, app: NSRunningApplication) -> [WindowEntry] {
        guard app.bundleIdentifier == bundleID else { return [] }
        return current(window).map { project, _ in
            WindowEntry(id: "\(app.processIdentifier):conductor:\(project.key)", pid: app.processIdentifier,
                        appName: app.localizedName ?? "Conductor", title: project.name, icon: app.icon,
                        element: window, minimized: false, hidden: app.isHidden, terminal: false, chatProject: project)
        }
    }
    @MainActor static func select(_ project: ChatProject, window: AXUIElement) -> Bool {
        guard let route = project.url, workspaceRoute(route) != nil else { return false }
        // Resolve the live link again; duplicate workspace titles are common.
        let matches = current(window).filter { $0.0.url == route }
        guard matches.count == 1 else { return false }
        return AXUIElementPerformAction(matches[0].1, kAXPressAction as CFString) == .success
    }
}

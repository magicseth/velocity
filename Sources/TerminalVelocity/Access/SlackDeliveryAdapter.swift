import AppKit
import ApplicationServices

struct SlackRoute: Equatable {
    let team: String
    let conversation: String
    var key: String { team + "/" + conversation }
    static func parse(_ raw: String) -> SlackRoute? {
        guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), url.host == "app.slack.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "client", parts[1].first == "T", ["C", "D", "G"].contains(parts[2].prefix(1)),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }) else { return nil }
        return .init(team: parts[1], conversation: parts[2])
    }
}

/// A native adapter for the active Slack workspace. Discovery visits a unique
/// sidebar destination to bind its stable route before the human approves it.
@MainActor struct SlackDeliveryAdapter: DeliveryAdapter {
    let descriptor = DeliveryCapability(id: "com.tinyspeck.slackmacgap", name: "Slack", capability: "shareLink")
    private func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        return Accessibility.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    private func nodes(_ root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = [], seen = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(1)
        func visit(_ node: AXUIElement, depth: Int) {
            guard depth < 24, seen.count < 2500, Date() < deadline, seen.insert(CFHash(node)).inserted else { return }
            AXUIElementSetMessagingTimeout(node, 0.05)
            let role = Accessibility.string(node, kAXRoleAttribute)
            let label = Accessibility.label(node)
            // Navigation and composer only; never traverse message lists or threads.
            if predicate(node) { found.append(node); return }
            if role == kAXListRole || role == kAXOutlineRole || label == "Media viewer" || label.hasPrefix("Thread") { return }
            if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole].contains(role) { return }
            for child in Accessibility.children(node) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }
    private func route(_ window: AXUIElement) -> SlackRoute? {
        let web = nodes(window) { Accessibility.string($0, kAXRoleAttribute) == "AXWebArea" }
        guard web.count == 1, let value = Accessibility.attribute(web[0], kAXURLAttribute) else { return nil }
        return SlackRoute.parse((value as? URL)?.absoluteString ?? (value as? String ?? ""))
    }
    private func composer(_ window: AXUIElement, name: String) -> (AXUIElement, AXUIElement)? {
        let containers = nodes(window) { Accessibility.label($0) == "composer" }
        var result: [(AXUIElement, AXUIElement)] = []
        for container in containers {
            let fields = nodes(container) { Accessibility.string($0, kAXRoleAttribute) == kAXTextAreaRole && Accessibility.string($0, kAXDescriptionAttribute) == "Message to " + name }
            let buttons = nodes(container) { Accessibility.string($0, kAXRoleAttribute) == kAXButtonRole && Accessibility.label($0) == "Send now" }
            let attachments = nodes(container) {
                let role = Accessibility.string($0, kAXRoleAttribute)
                let label = Accessibility.label($0).lowercased()
                return role == kAXListRole || role == kAXImageRole || (role == kAXButtonRole && label.hasPrefix("remove"))
            }
            if fields.count == 1 && buttons.count == 1 && attachments.isEmpty { result.append((fields[0], buttons[0])) }
        }
        return result.count == 1 ? result[0] : nil
    }
    static func preferredNames(_ names: [String], query: String) -> [String] {
        let exact = names.filter { $0.caseInsensitiveCompare(query) == .orderedSame }
        if !exact.isEmpty { return exact }
        let people = names.filter { !$0.contains(",") && $0.lowercased().hasPrefix(query.lowercased() + " ") }
        return people.isEmpty ? names : people
    }
    func recipients(matching query: String) async throws -> [DeliveryRecipient] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.id).first else {
            throw AIGrouping.Failure("Open Slack and the workspace you want to send in, then prepare the request again.")
        }
        let name = query.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#@")))
        guard !name.isEmpty else { throw AccessError.unsupported }
        var filteredWindow: AXUIElement?
        var previousFilter = ""
        func searchFields(_ window: AXUIElement) -> [AXUIElement] {
            nodes(window) { Accessibility.string($0, kAXRoleAttribute) == kAXTextFieldRole && Accessibility.string($0, kAXDescriptionAttribute) == "Channel or user name" }
        }
        defer {
            if let window = filteredWindow, let field = searchFields(window).first,
               Accessibility.string(field, kAXValueAttribute) == name {
                AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, previousFilter as CFString)
            }
        }
        func candidates() -> [(ConversationDestination, AXUIElement)] {
            windows(app).flatMap { window in
                Conversations.current(window: window, appID: descriptor.id).filter { $0.0.name.localizedCaseInsensitiveContains(name) }.map { ($0.0, window) }
            }
        }
        var found = candidates()
        if !found.contains(where: { $0.0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let available = windows(app).compactMap { window in searchFields(window).first.map { (window, $0) } }
            guard available.count == 1 else { throw AIGrouping.Failure("Open the desired Slack workspace and try again.") }
            let (window, field) = available[0]
            previousFilter = Accessibility.string(field, kAXValueAttribute)
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, name as CFString) == .success else {
                throw AIGrouping.Failure("Slack’s conversation search is unavailable. Open the destination in Slack and try again.")
            }
            filteredWindow = window
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 100_000_000)
                found = candidates()
                if !found.isEmpty && Self.preferredNames(found.map { $0.0.name }, query: name).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame || $0.lowercased().hasPrefix(name.lowercased() + " ") }) { break }
            }
        }
        let preferred = Self.preferredNames(found.map { $0.0.name }, query: name)
        let matches = found.filter { preferred.contains($0.0.name) }
        guard matches.count == 1 else {
            throw AIGrouping.Failure(matches.isEmpty ? "No Slack sidebar conversation matched. Open the person or channel in Slack’s active workspace and try again." : "Several Slack destinations match. Use the full person or channel name.")
        }
        let (destination, window) = matches[0]
        func resolved() -> DeliveryRecipient? {
            guard let route = route(window), route.team == destination.scope, composer(window, name: destination.name) != nil else { return nil }
            let title = Accessibility.string(window, kAXTitleAttribute)
            guard title.hasPrefix(destination.name + " ("),
                  !title.hasPrefix(destination.name + " (DM)") || ["D", "G"].contains(route.conversation.prefix(1)),
                  self.route(window) == route else { return nil }
            return DeliveryRecipient(id: route.key, name: destination.name, handle: route.key, accountID: route.team,
                                     adapterID: descriptor.id, adapterName: "Slack · " + (title.components(separatedBy: " - ").dropFirst().first ?? route.team))
        }
        if let recipient = resolved() {
            try await Task.sleep(nanoseconds: 400_000_000)
            if resolved() == recipient { return [recipient] }
        }
        app.unhide(); app.activate(options: [])
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        try await Task.sleep(nanoseconds: 300_000_000)
        guard Conversations.select(destination, window: window) else { throw AIGrouping.Failure("Couldn’t select that Slack destination. Open it in Slack and try again.") }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let recipient = resolved() {
            try await Task.sleep(nanoseconds: 400_000_000)
            if resolved() == recipient { return [recipient] }
        }
        }
        throw AIGrouping.Failure("Slack’s destination could not be verified. Nothing was sent.")
    }
    func send(_ preview: LinkDeliveryPreview) async throws -> Bool {
        guard preview.recipient.adapterID == descriptor.id, MessageLinks.validURL(preview.body),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.id).first else { throw AccessError.unavailable }
        app.unhide(); app.activate(options: [])
        try await Task.sleep(nanoseconds: 150_000_000)
        func target() throws -> (AXUIElement, AXUIElement) {
            let matches = windows(app).filter { route($0)?.key == preview.recipient.id && route($0)?.team == preview.recipient.accountID }
            guard matches.count == 1, let pair = composer(matches[0], name: preview.recipient.name) else { throw AccessError.stale }
            return pair
        }
        let (field, _) = try target()
        guard Accessibility.string(field, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGrouping.Failure("Slack already has a draft. It was left unchanged; clear or send it yourself before trying again.")
        }
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, preview.body as CFString) == .success else {
            throw AIGrouping.Failure("Slack wouldn’t accept the draft through Accessibility. Nothing was sent.")
        }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let (currentField, button) = try target()
            guard CFEqual(field, currentField), Accessibility.string(currentField, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines) == preview.body else {
                throw AIGrouping.Failure("The Slack draft changed. Sending stopped; review the draft in Slack.")
            }
            if Accessibility.attribute(button, kAXEnabledAttribute) as? Bool == true {
                // Native AXPress targets this exact button, never a global Return key.
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    throw AIGrouping.Failure("Slack did not confirm the send. Check the conversation before trying again.")
                }
                for _ in 0..<10 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let (after, _) = try target()
                    if Accessibility.string(after, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                }
                throw AIGrouping.Failure("Slack did not clear the composer after Send. Check the conversation before trying again; the result is unconfirmed.")
            }
        }
        throw AIGrouping.Failure("Slack didn’t enable Send. The link is left as a draft; nothing was sent by Velocity.")
    }
}

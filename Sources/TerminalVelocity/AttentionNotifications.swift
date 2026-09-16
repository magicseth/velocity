import AppKit
import UserNotifications

// Keep a request latched through brief AX read failures and blinking title markers.
struct AttentionTransitions {
    private var lastSeen: [String: Date] = [:]
    mutating func update(_ current: Set<String>, now: Date = Date()) -> Set<String> {
        lastSeen = lastSeen.filter { current.contains($0.key) || now.timeIntervalSince($0.value) < 10 }
        let fresh = current.subtracting(lastSeen.keys)
        for key in current { lastSeen[key] = now }
        return fresh
    }
}

@MainActor final class AttentionNotifications: NSObject, UNUserNotificationCenterDelegate {
    var openAttention: (() -> Void)?
    var openEntry: ((WindowEntry) -> Void)?
    var answerEntry: ((WindowEntry, AttentionApproval) -> Void)?
    private var approvals: [String: AttentionApproval] = [:]
    var changed: ((Int, String?) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var transitions = AttentionTransitions()
    private var entries: [WindowEntry] = []
    private var authorized = false
    private var lastIssue: String?
    private var notificationTarget: (token: String, entry: WindowEntry, launch: Date)?

    static func target(_ original: WindowEntry, in entries: [WindowEntry]) -> WindowEntry? {
        let matches = entries.filter {
            $0.id == original.id && $0.pid == original.pid &&
            $0.attentionTaskTitle == original.attentionTaskTitle
        }
        return matches.count == 1 ? matches[0] : nil
    }
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "agentNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agentNotifications") }
    }

    func start(requestAuthorization: Bool = true) {
        center.delegate = self
        let yes = UNNotificationAction(identifier: "answer-yes-once", title: "Yes, once", options: [.foreground, .authenticationRequired])
        let open = UNNotificationAction(identifier: "open-terminal", title: "Open terminal", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "agent-confirmation", actions: [yes, open], intentIdentifiers: [], options: [])])
        if requestAuthorization && enabled { requestPermission() }
    }
    func requestPermission() {
        Task {
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
                lastIssue = authorized ? nil : "Notifications are disabled in macOS Settings."
                observe(entries)
            } catch {
                lastIssue = "Couldn’t enable notifications: " + error.localizedDescription
                changed?(Self.waiting(entries).count, lastIssue)
            }
        }
    }
    func toggle() {
        enabled.toggle()
        if enabled { requestPermission() }
        else {
            center.removeDeliveredNotifications(withIdentifiers: ["agent-attention"])
            center.removePendingNotificationRequests(withIdentifiers: ["agent-attention"])
        }
    }
    static func waiting(_ entries: [WindowEntry]) -> [String: WindowEntry] {
        var result: [String: WindowEntry] = [:]
        for entry in entries where entry.attention.needsAttention {
            let key = (entry.windowKey ?? String(entry.pid)) + ":" + entry.attentionTaskTitle
            if result[key] == nil || entry.isTab { result[key] = entry }
        }
        return result
    }
    func observe(_ entries: [WindowEntry]) {
        self.entries = entries
        let waiting = Self.waiting(entries)
        changed?(waiting.count, lastIssue)
        guard enabled, authorized else { return }
        let fresh = transitions.update(Set(waiting.keys))
        if waiting.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ["agent-attention"])
            center.removePendingNotificationRequests(withIdentifiers: ["agent-attention"])
        }
        guard !fresh.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "Agent needs your input" : "\(fresh.count) agents need your input"
        let targets = fresh.sorted().compactMap { waiting[$0] }
        let names = targets.prefix(3).map { AIGrouping.metadata($0.title, limit: 140) }
        notificationTarget = nil
        if targets.count == 1, let entry = targets.first,
           let launch = NSRunningApplication(processIdentifier: entry.pid)?.launchDate {
            let token = UUID().uuidString
            notificationTarget = (token, entry, launch)
            content.userInfo = ["targetToken": token]
            if let destination = AttentionDestination(entry: entry, launch: launch),
               let data = try? JSONEncoder().encode(destination) {
                content.userInfo["destination"] = data
            }
            let presentation = AttentionPresentation(entry)
            content.title = presentation.project + " needs your input"
            content.subtitle = presentation.task
            content.body = "Question preview unavailable. Click to open this terminal."
            Task { @MainActor [weak self] in
                let details = await Task.detached(priority: .utility) {
                    let preview = WindowCatalog.notificationPreview(entry)
                    let text = preview == nil ? nil : WindowCatalog.promptPreview(entry)
                    return (preview, text.flatMap { AttentionApproval.parse($0) })
                }.value
                let preview = details.0
                guard let self, enabled, notificationTarget?.token == token,
                      Self.target(entry, in: self.entries) != nil else { return }
                if let preview {
                    content.body = "Terminal excerpt:\n" + preview + "\nClick to reply in the terminal."
                }
                if let approval = details.1 {
                    approvals = approvals.filter { Date().timeIntervalSince($0.value.created) <= 120 }
                    approvals[token] = approval
                    content.categoryIdentifier = "agent-confirmation"
                    content.body = approval.prompt
                }
                content.sound = .default
                deliver(content, id: "agent-attention")
            }
            return
        } else {
            content.body = names.joined(separator: "\n") + "\nClick to choose an agent."
        }
        content.sound = .default
        deliver(content, id: "agent-attention")
    }
    func test() {
        Task {
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
                guard authorized else { lastIssue = "Allow Terminal Velocity in System Settings → Notifications."; changed?(Self.waiting(entries).count, lastIssue); return }
                let content = UNMutableNotificationContent()
                content.title = "Terminal Velocity notifications are working"
                content.body = "Agent requests will appear here. Click to open Attention."
                content.sound = .default
                deliver(content, id: "attention-test")
            } catch { changed?(Self.waiting(entries).count, error.localizedDescription) }
        }
    }
    private func deliver(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.lastIssue = error.localizedDescription; self?.changed?(Self.waiting(self?.entries ?? []).count, error.localizedDescription) } }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let answerYes = response.actionIdentifier == "answer-yes-once"
        if answerYes || response.actionIdentifier == "open-terminal" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let token = response.notification.request.content.userInfo["targetToken"] as? String
            let data = response.notification.request.content.userInfo["destination"] as? Data
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, let destination = try? JSONDecoder().decode(AttentionDestination.self, from: data) {
                    let entry = await Task.detached(priority: .userInitiated) { destination.liveEntry() }.value
                    if let entry {
                        if answerYes, let token, let approval = approvals.removeValue(forKey: token), approval.matches(WindowCatalog.promptPreview(entry)) {
                            answerEntry?(entry, approval)
                        } else { openEntry?(entry) }
                    }
                    else { openAttention?() }
                } else if let target = notificationTarget, token == target.token,
                   NSRunningApplication(processIdentifier: target.entry.pid)?.launchDate == target.launch,
                   let entry = Self.target(target.entry, in: entries) {
                    openEntry?(entry)
                } else {
                    // Old, ambiguous, or replaced targets must never open an unrelated tab.
                    openAttention?()
                }
            }
        }
        completionHandler()
    }
}

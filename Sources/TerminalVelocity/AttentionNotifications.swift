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
    var changed: ((Int, String?) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var transitions = AttentionTransitions()
    private var entries: [WindowEntry] = []
    private var authorized = false
    private var lastIssue: String?
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "agentNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agentNotifications") }
    }

    func start() {
        center.delegate = self
        if enabled { requestPermission() }
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
        let names = fresh.sorted().compactMap { waiting[$0] }.prefix(3).map { AIGrouping.metadata($0.title, limit: 140) }
        content.body = names.joined(separator: "\n") + "\nClick to open Attention in Terminal Velocity."
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
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor [weak self] in self?.openAttention?() }
        }
        completionHandler()
    }
}

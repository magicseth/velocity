import AppKit
import SwiftUI

extension AppDelegate {
    func makeBroker() -> ResourceBroker {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velocity/Access", isDirectory: true)
        let storage = try? AccessStorage(directory: directory)
        let broker = ResourceBroker(storage: storage) { [weak self] entry, action in
            guard let self else { return false }
            // Actions are limited to this exact catalog entry. No objective companions,
            // launch URLs, shell commands, or arbitrary adapter calls cross this boundary.
            guard self.model.all.contains(where: { $0.id == entry.id && $0.memoryKey == entry.memoryKey && $0.title == entry.title }),
                  entry.launchURL == nil, ResourceTarget.isCurrent(entry) else { return false }
            let result: Bool
            switch action {
            case .open:
                if let tab = entry.browserTab {
                    guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return false }
                    app.unhide()
                    guard app.activate(options: []) else { return false }
                    result = BrowserTabs.select(tab, requireUnchanged: true)
                } else { result = await self.focusGroup([], selected: entry) }
            case .close: result = await CloseResult.close(entry)
            }
            self.refresh()
            return result
        }
        broker.pendingChanged = { [weak self] in
            self?.updateAccessAttention()
        }
        return broker
    }
    func updateAccessAttention() {
        let pending = resourceBroker.requests.filter { $0.status == .pending }.count
        status.button?.image = Branding.menuIcon(attention: pending > 0 || attentionCount > 0)
        if pending > 0 { status.button?.toolTip = "\(pending) access requests — open Agent Access to review" }
        else { status.button?.toolTip = attentionCount > 0 ? "\(attentionCount) agents need input" : "Velocity — \(model.shortcut)" }
    }
    @objc func showAgentAccess() {
        if accessWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Velocity · Agent Access"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AccessView(broker: resourceBroker, server: accessServer))
            window.center()
            accessWindow = window
        }
        panel.orderOut(nil)
        NSApp.activate()
        accessWindow?.makeKeyAndOrderFront(nil)
    }
}

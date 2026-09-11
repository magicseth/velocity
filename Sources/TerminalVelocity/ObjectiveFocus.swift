import AppKit
import ApplicationServices

@MainActor final class ObjectiveFocus {
    private var hidden: [NSRunningApplication] = []
    private var minimized: [AXUIElement] = []
    var active: Bool { !hidden.isEmpty || !minimized.isEmpty }
    func restore() {
        for window in minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        for app in hidden where !app.isTerminated { app.unhide() }
        minimized = []; hidden = []
    }
    func isolate(_ entries: [WindowEntry], among all: [WindowEntry]) {
        restore()
        let pids = Set(entries.map(\.pid))
        let keys = Set(entries.compactMap(\.windowKey))
        guard !keys.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !pids.contains(app.processIdentifier) && !app.isHidden {
            if app.hide() { hidden.append(app) }
        }
        var seen: Set<String> = []
        for entry in all where pids.contains(entry.pid) {
            guard let key = entry.windowKey, seen.insert(key).inserted, !keys.contains(key), let window = entry.element,
                  WindowCatalog.attribute(window, kAXMinimizedAttribute) as? Bool == false else { continue }
            if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success { minimized.append(window) }
        }
    }
}

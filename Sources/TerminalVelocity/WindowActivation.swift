import AppKit
import ApplicationServices

/// Activation and tab selection are deliberately separate from catalog scans.
extension WindowCatalog {
    static func liveTab(for entry: WindowEntry) -> AXUIElement? {
        guard let original = entry.tab, let window = entry.element else { return nil }
        let candidates = tabs(in: window)
        if let same = candidates.first(where: { CFEqual($0.0, original) }) { return same.0 }
        // Rebuilt tab controls are safe to resolve only by a unique title.
        func normalized(_ title: String) -> String {
            title.replacingOccurrences(of: #"\[\s*[!.]\s*\]"#, with: "[!]", options: .regularExpression)
        }
        let matches = candidates.filter { normalized($0.1) == normalized(entry.title) }
        return matches.count == 1 ? matches[0].0 : nil
    }

    static func tabIsSelected(_ tab: AXUIElement) -> Bool? {
        if let value = Accessibility.attribute(tab, "AXSelected") as? NSNumber { return value.boolValue }
        if let value = Accessibility.attribute(tab, kAXValueAttribute) as? NSNumber { return value.boolValue }
        return nil
    }

    @MainActor static func selectFocusedTab(_ entry: WindowEntry) async -> Bool {
        // Browser scripting has already selected its stable tab ID.
        if let browserTab = entry.browserTab { return await BrowserTabs.select(browserTab) }
        guard entry.tab != nil else { return true }
        guard let tab = liveTab(for: entry) else { return false }
        if tabIsSelected(tab) == true { return true }
        let pressed = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(60))
        if tabIsSelected(tab) == true { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
        // Terminal may expose a selectable radio button instead of a pressable tab.
        let setValue = AXUIElementSetAttributeValue(tab, kAXValueAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(60))
        if let selected = tabIsSelected(tab) { return selected }
        return pressed == .success || setValue == .success
    }

    @MainActor static func focus(_ entry: WindowEntry) async -> Bool {
        guard entry.cachedTerminal == nil else { JuliaLog.note("focus: “\(entry.title.prefix(30))” is a cached terminal, not a live window"); return false }
        // NSRunningApplication(processIdentifier:) intermittently came back nil inside Velocity for
        // apps that were plainly running (Terminal 792, Chrome 15789 — "is gone"), and the whole
        // group failed: "i saw the chrome tab change in the background but it didn't come to the
        // foreground". The window-server raise needs only the pid; the app object is only for
        // activation. Look harder, and treat a live pid as alive.
        let app = NSRunningApplication(processIdentifier: entry.pid)
            ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier == entry.pid }
        let alive = (kill(entry.pid, 0) == 0 || errno == EPERM)
        guard alive, app?.isTerminated != true else { JuliaLog.note("focus: \(entry.appName) (pid \(entry.pid)) is gone"); return false }
        if app == nil { JuliaLog.note("focus: no app object for \(entry.appName) (pid \(entry.pid)); raising through the window server") }
        if let browserTab = entry.browserTab {
            // Scripting owns the exact browser destination. AX windows from the
            // scan may have been recreated or associated with another tab; never
            // raise those cached windows after selecting a stable browser ID.
            // A failed check is not a reason to leave Chrome in the back: the script may have switched
            // the tab and only mis-reported it. Bring the browser forward anyway; report the miss.
            let selected = await BrowserTabs.select(browserTab)
            if !selected { JuliaLog.note("focus: tab select not confirmed for “\(entry.title.prefix(30))”; raising the browser anyway") }
            app?.unhide()
            // ONE BROWSER WINDOW: the tab is selected and its window ordered front inside the
            // browser; the window server then puts that window — the browser's topmost — in
            // front alone. Activating the app instead brought every browser window along.
            if let wid = WindowRaise.topWindowID(pid: entry.pid), await WindowRaise.bring(pid: entry.pid, windowID: wid) {
                WindowRaise.glow(windowID: wid, tint: WindowRaise.currentTint); JuliaLog.note("focus: one browser window via window server (verified)"); return true
            }
            JuliaLog.note("focus: browser window server raise not honoured; activating the app")
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
                guard let app else { JuliaLog.note("focus: can't activate \(entry.appName) without its app object"); return false }
                if NSApp.isActive {
                    NSApp.yieldActivation(to: app)
                    guard app.activate(from: .current, options: []) else { JuliaLog.note("focus: \(entry.appName) refused activation"); return false }
                } else {
                    guard app.activate(options: []) else { JuliaLog.note("focus: \(entry.appName) refused activation"); return false }
                }
            }
            return selected
        }
        if app?.isHidden == true { app?.unhide() }
        // Only when it IS minimized: writing the attribute to an unminimized window made
        // Terminal order every window forward (measured).
        if let window = entry.element, entry.minimized {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if result == .invalidUIElement { JuliaLog.note("focus: “\(entry.title.prefix(30))” window no longer exists (stale scan)"); return false }
        }
        // ONE WINDOW, NOT THE APP ("i double clicked on docs, and it foregrounded way too
        // many windows"): the window server puts exactly this window in front. The app
        // activation below stays as the fallback.
        if let window = entry.element, let wid = WindowRaise.windowID(of: window) {
            if await WindowRaise.bring(pid: entry.pid, windowID: wid, element: window) {
                if entry.tab != nil { _ = await WindowCatalog.selectFocusedTab(entry) }
                WindowRaise.glow(windowID: wid, tint: WindowRaise.currentTint)
                JuliaLog.note("focus: one window via window server — \(entry.appName) “\(entry.title.prefix(30))” (verified)")
                return true
            }
            JuliaLog.note("focus: window server raise NOT verified for \(entry.appName) “\(entry.title.prefix(30))”; activating the app")
        } else {
            JuliaLog.note("focus: no window id for \(entry.appName) “\(entry.title.prefix(30))” (element=\(entry.element != nil)); activating the app")
        }
        // Keep our palette active until macOS accepts the handoff. Hiding our
        // last window first can give activation to Finder instead.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
            guard let app else { JuliaLog.note("focus: can't activate \(entry.appName) without its app object"); return false }
            let activated: Bool
            if NSApp.isActive {
                NSApp.yieldActivation(to: app)
                activated = app.activate(from: .current, options: [])
            } else {
                activated = app.activate(options: [])
            }
            guard activated else { JuliaLog.note("focus: \(entry.appName) refused activation"); return false }
        }
        guard let window = entry.element else { return true }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Some apps restore their previously focused window during activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if raised != .success { JuliaLog.note("focus: AX raise of “\(entry.title.prefix(30))” returned \(raised.rawValue)") }
        return raised == .success
    }
}

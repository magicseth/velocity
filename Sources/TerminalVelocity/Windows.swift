import AppKit
import ApplicationServices
import CryptoKit

struct WindowEntry: Identifiable, @unchecked Sendable {
    let id: String
    let pid: pid_t
    let appName: String
    var title: String
    let icon: NSImage?
    let element: AXUIElement?
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
    var browserPinned = false
    var documentFolder: String {
        guard let documentPath else { return "" }
        return (documentPath as NSString).deletingLastPathComponent
    }
    var searchText: String {
        [title, browserTab?.url, documentPath, browserProfile, chatProject?.mode].compactMap { $0 }.joined(separator: " ")
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
    var attention: AgentAttention { AgentAttention.detect(title: title, terminal: terminal) }
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
    var isTab: Bool { tab != nil || browserTab != nil }
    var subtitle: String {
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

struct WindowSnapshot: @unchecked Sendable {
    var entries: [WindowEntry]
    var notices: [String]
}

enum WindowCatalog {
    static let terminalIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper"
    ]

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func documentPath(_ element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXDocumentAttribute) else { return nil }
        return localDocumentPath(String(describing: value))
    }

    static func localDocumentPath(_ value: String) -> String? {
        if value.hasPrefix("/") { return (value as NSString).standardizingPath }
        guard let url = URL(string: value), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }

    // Read tab controls, never terminal contents or browser page contents.
    // Apps differ in how deeply they nest the tab strip in their window chrome.
    static func tabs(in window: AXUIElement) -> [(AXUIElement, String)] {
        var found: [(AXUIElement, String)] = []
        var remaining = 3000
        func walk(_ element: AXUIElement, depth: Int, inTabGroup: Bool) {
            guard depth < 14, remaining > 0 else { return }
            remaining -= 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if ["AXTextArea", "AXWebArea", "AXTable", "AXOutline"].contains(role) { return }
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            let isTab = role == "AXTab" || subrole == "AXTabButton" || (inTabGroup && role == kAXRadioButtonRole)
            if isTab {
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { attribute(element, $0) as? String }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let title { found.append((element, title)) }
                return
            }
            let children = (role == kAXTabGroupRole ? attribute(element, "AXTabs") as? [AXUIElement] : nil)
                ?? attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children {
                walk(child, depth: depth + 1, inTabGroup: inTabGroup || role == kAXTabGroupRole)
            }
        }
        walk(window, depth: 0, inTabGroup: false)
        return found
    }

    static func installedApps() -> [WindowEntry] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var found: [String: WindowEntry] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                guard !running.contains(path), let bundle = Bundle(url: url),
                      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true,
                      bundle.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                found[path] = WindowEntry(id: "launch:" + path, pid: 0, appName: name, title: name,
                    icon: NSWorkspace.shared.icon(forFile: path), element: nil, minimized: false, hidden: false,
                    terminal: terminalIDs.contains(bundle.bundleIdentifier ?? ""),
                    browser: BrowserTabs.supported.contains(bundle.bundleIdentifier ?? ""), launchURL: url)
            }
        }
        return found.values.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    // Observe only the foreground window and known tab controls, without a full scan.
    static func promptPreview(_ entry: WindowEntry) -> String {
        guard entry.terminal, let window = entry.element else { return "No accessible terminal text is available." }
        if let tab = entry.tab {
            let selected = (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true
                || (attribute(tab, "AXSelected") as? Bool) == true
            guard selected else { return "This tab is in the background. Open it to read its current prompt." }
        }
        var remaining = 400
        func read(_ node: AXUIElement, depth: Int) -> String? {
            guard remaining > 0, depth < 12 else { return nil }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.1)
            let role = attribute(node, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return nil }
            if role == kAXTextAreaRole, let value = attribute(node, kAXValueAttribute) as? String, !value.isEmpty {
                return String(value.suffix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let value = read(child, depth: depth + 1) { return value }
            }
            return nil
        }
        return read(window, depth: 0) ?? "This terminal does not expose readable text. Open it to see the prompt."
    }

    static func position(of entry: WindowEntry?) -> CGPoint? {
        guard let window = entry?.element,
              let raw = attribute(window, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func focusedEntry(app: NSRunningApplication, known: [WindowEntry]) -> WindowEntry? {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let raw = attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.1)
        let candidates = known.filter { $0.pid == pid && $0.element.map { CFEqual($0, window) } == true }
        // A selected tab is more specific than its containing window.
        if let selected = candidates.first(where: {
            guard let tab = $0.tab else { return false }
            return (attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true
                || (attribute(tab, "AXSelected") as? Bool) == true
        }) { return selected }
        let title = attribute(window, kAXTitleAttribute) as? String ?? app.localizedName ?? "Application"
        if let matching = candidates.first(where: { !$0.isTab && $0.title == title }) { return matching }
        return WindowEntry(id: "\(pid):focused:\(CFHash(window))", pid: pid,
                           appName: app.localizedName ?? "Application", title: title, icon: app.icon,
                           element: window, minimized: false, hidden: false,
                           terminal: terminalIDs.contains(app.bundleIdentifier ?? ""),
                           browser: BrowserTabs.supported.contains(app.bundleIdentifier ?? ""),
                           documentPath: documentPath(window))
    }

    static func scan(frontmost: pid_t?, browserTabsEnabled: Bool = false) -> WindowSnapshot {
        let running = NSWorkspace.shared.runningApplications
        let audioPIDs = AudioActivity.activeAppPIDs(apps: running)
        let regularApps = running.filter { $0.activationPolicy == .regular }
        let apps = running.filter { app in
            let ownedHelper = app.activationPolicy != .regular && regularApps.contains { owner in
                guard let path = app.executableURL?.path ?? app.bundleURL?.path, let bundle = owner.bundleURL?.path else { return false }
                return path.hasPrefix(bundle + "/")
            }
            return !ownedHelper && (app.activationPolicy == .regular || audioPIDs.contains(app.processIdentifier)) && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            if ($0.processIdentifier == frontmost) != ($1.processIdentifier == frontmost) { return $0.processIdentifier == frontmost }
            return ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }
        var entries: [WindowEntry] = []
        var notices: [String] = []
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "Application"
            let terminal = terminalIDs.contains(app.bundleIdentifier ?? "")
            let browser = BrowserTabs.supported.contains(app.bundleIdentifier ?? "")
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            var appEntries: [WindowEntry] = []
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.15)
                let title = (attribute(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
                appEntries.append(WindowEntry(id: "\(pid):window:\(CFHash(window))", pid: pid, appName: name,
                    title: title.isEmpty ? "Untitled window" : title, icon: app.icon,
                    element: window, minimized: minimized, hidden: app.isHidden, terminal: terminal,
                    audio: audioPIDs.contains(pid) ? .appOutput : .none, browser: browser,
                    documentPath: documentPath(window), browserProfile: browser ? profileName(windowTitle: title, appName: name) : nil))
                appEntries.append(contentsOf: ChatProjects.scan(window: window, app: app))
                appEntries.append(contentsOf: ConductorWorkspaces.scan(window: window, app: app))
                appEntries.append(contentsOf: Conversations.scan(window: window, app: app))
                for tab in tabs(in: window) {
                    appEntries.append(WindowEntry(id: "\(pid):window:\(CFHash(window)):tab:\(CFHash(tab.0))", pid: pid,
                        appName: name, title: tab.1, icon: app.icon, element: window,
                        minimized: minimized, hidden: app.isHidden, terminal: terminal, tab: tab.0,
                        audio: browser ? tabAudio(tab.0) : (audioPIDs.contains(pid) ? .appOutput : .none), browser: browser,
                        documentPath: documentPath(tab.0), browserProfile: browser ? profileName(windowTitle: title, appName: name) : nil))
                }
            }
            if browser && browserTabsEnabled {
                let result = BrowserTabs.scan(browserID: app.bundleIdentifier!)
                if let error = result.error { notices.append(error) }
                else {
                    let accessibleTabs = appEntries.filter { $0.tab != nil }
                    appEntries.removeAll { $0.tab != nil }
                    let windowAssociations = browserWindowAssociations(windows: appEntries.filter { !$0.isTab && $0.element != nil }, accessibleTabs: accessibleTabs, scriptTabs: result.tabs, appName: name)
                    for tab in result.tabs {
                        let matches = accessibleTabs.filter { cleanTabTitle($0.title) == tab.title }
                        // Never attach one tab's speaker state to a different
                        // duplicate-title tab. Ambiguous matches remain unknown.
                        var match = matches.count == 1 && result.tabs.filter({ $0.title == tab.title }).count == 1 ? matches.first : nil
                        let associatedWindow = windowAssociations[tab.windowID]
                        let matchedWindow = associatedWindow?.element
                        if let window = matchedWindow {
                            let windowTabs = accessibleTabs.filter { $0.element.map { CFEqual($0, window) } == true }
                            let scriptedCount = result.tabs.filter { $0.windowID == tab.windowID }.count
                            if windowTabs.count == scriptedCount, windowTabs.indices.contains(tab.index - 1),
                               cleanTabTitle(windowTabs[tab.index - 1].title) == tab.title {
                                match = windowTabs[tab.index - 1]
                            }
                        }
                        appEntries.append(WindowEntry(id: "\(pid):browser:\(tab.windowID):\(tab.tabID)",
                            pid: pid, appName: name, title: tab.title.isEmpty ? tab.url : tab.title,
                            icon: app.icon, element: matchedWindow ?? match?.element, minimized: tab.minimized, hidden: app.isHidden,
                            terminal: false, tab: match?.tab, browserTab: tab,
                            audio: match?.audio ?? .none, browser: true,
                            browserProfile: profileName(windowTitle: tab.windowTitle, appName: name) ?? associatedWindow?.browserProfile ?? match?.browserProfile ?? (tab.browserID == "com.google.Chrome" ? "Profile unavailable" : nil),
                            browserPinned: match?.tab.map { tabPinned($0) } ?? false))
                    }
                }
            }
            if windows.isEmpty {
                appEntries.append(WindowEntry(id: "\(pid):app", pid: pid, appName: name,
                    title: name, icon: app.icon, element: nil, minimized: false,
                    hidden: app.isHidden, terminal: terminal,
                    audio: audioPIDs.contains(pid) ? .appOutput : .none, browser: browser))
            }
            if app.bundleIdentifier == "com.google.Chrome" {
                let profiles = ChromeProfileIcon.load()
                appEntries = appEntries.map { original in
                    var entry = original
                    entry.browserProfileIcon = ChromeProfileIcon.matching(entry.browserProfile, profiles: profiles)
                    return entry
                }
            }
            entries.append(contentsOf: appEntries)
        }
        return WindowSnapshot(entries: applyingBrowserAudio(entries) + installedApps(), notices: notices)
    }

    static func browserTitleWithoutAppSuffix(_ title: String, appName: String) -> String {
        var title = title
        // AX window titles may append the application and browser profile.
        if let suffix = title.range(of: " - " + appName, options: .backwards),
           title[suffix.upperBound...].isEmpty || title[suffix.upperBound...].hasPrefix(" - ") {
            title = String(title[..<suffix.lowerBound])
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func browserWindowTitle(_ title: String, appName: String) -> String {
        cleanTabTitle(browserTitleWithoutAppSuffix(title, appName: appName))
    }

    static func applyingBrowserAudio(_ entries: [WindowEntry]) -> [WindowEntry] {
        let windows = entries.filter { $0.browser && !$0.isTab && $0.windowKey != nil }
        return entries.map { original in
            var entry = original
            guard entry.browser else { return entry }
            if !entry.isTab {
                let annotation = AudioBadge.fromTabMetadata([browserTitleWithoutAppSuffix(entry.title, appName: entry.appName)])
                if annotation != .none { entry.audio = annotation }
            } else if entry.audio == .none, let key = entry.windowKey,
                      let window = windows.first(where: { $0.windowKey == key }),
                      browserWindowTitle(window.title, appName: window.appName) == cleanTabTitle(entry.title) {
                let matchingTabs = entries.filter { $0.isTab && $0.windowKey == key && cleanTabTitle($0.title) == cleanTabTitle(entry.title) }
                // The window title describes the active tab. Only transfer its
                // annotation when exactly one tab matches; never guess between duplicates.
                if matchingTabs.count == 1 {
                    entry.audio = AudioBadge.fromTabMetadata([browserTitleWithoutAppSuffix(window.title, appName: window.appName)])
                }
            }
            return entry
        }
    }

    static func removingBrowserWindowDuplicates(_ entries: [WindowEntry]) -> [WindowEntry] {
        let tabs = entries.filter { $0.browser && $0.isTab && $0.windowKey != nil }
        return entries.filter { window in
            guard window.browser, !window.isTab, let key = window.windowKey else { return true }
            return !tabs.contains { tab in
                tab.windowKey == key && (
                    tab.browserTab?.isActive == true ||
                    (window.audio == .playing && tab.audio == .playing) ||
                    browserWindowTitle(window.title, appName: window.appName) == browserWindowTitle(tab.title, appName: tab.appName)
                )
            }
        }
    }

    static func cleanTabTitle(_ title: String) -> String {
        var title = AudioBadge.removingMemoryAnnotation(title)
        for suffix in [" - Audio playing", " - Audio muted", ", Audio playing", ", Audio muted", " - Playing audio"] {
            if title.lowercased().hasSuffix(suffix.lowercased()) { title.removeLast(suffix.count) }
        }
        return title
    }

    static func tabPinned(_ tab: AXUIElement) -> Bool {
        [kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute]
            .compactMap { attribute(tab, $0) as? String }.joined(separator: " ").lowercased().contains("pinned")
    }

    static func tabAudio(_ tab: AXUIElement) -> AudioBadge {
        var labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(tab, $0) as? String }
        // Safari exposes a Mute/Unmute button in its tab. Only inspect the tab's
        // own controls, never mute buttons in webpage contents.
        for child in (attribute(tab, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(12) {
            labels += [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(child, $0) as? String }
        }
        return AudioBadge.fromTabMetadata(labels)
    }

    static func updatingAudio(_ entries: [WindowEntry]) -> [WindowEntry] {
        let pids = AudioActivity.activeAppPIDs(apps: NSWorkspace.shared.runningApplications)
        let updated = entries.map { original in
            var entry = original
            if entry.terminal || (entry.browser && !entry.isTab), let source = entry.tab ?? entry.element {
                AXUIElementSetMessagingTimeout(source, 0.1)
                if let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap({ attribute(source, $0) as? String }).first(where: { !$0.isEmpty }) {
                    entry.title = title
                }
            }
            if entry.browser && entry.isTab { entry.audio = entry.tab.map(tabAudio) ?? .none }
            else { entry.audio = pids.contains(entry.pid) ? .appOutput : .none }
            return entry
        }
        return applyingBrowserAudio(updated)
    }

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
        if let value = attribute(tab, "AXSelected") as? NSNumber { return value.boolValue }
        if let value = attribute(tab, kAXValueAttribute) as? NSNumber { return value.boolValue }
        return nil
    }

    @MainActor static func selectFocusedTab(_ entry: WindowEntry) async -> Bool {
        // Browser scripting has already selected its stable tab ID.
        if let browserTab = entry.browserTab { return BrowserTabs.select(browserTab) }
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

    @MainActor static func focus(_ entry: WindowEntry) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return false }
        if let browserTab = entry.browserTab {
            // Scripting owns the exact browser destination. AX windows from the
            // scan may have been recreated or associated with another tab; never
            // raise those cached windows after selecting a stable browser ID.
            app.unhide()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
                if NSApp.isActive {
                    NSApp.yieldActivation(to: app)
                    guard app.activate(from: .current, options: []) else { return false }
                } else {
                    guard app.activate(options: []) else { return false }
                }
            }
            return BrowserTabs.select(browserTab)
        }
        app.unhide()
        if let window = entry.element {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if result == .invalidUIElement { return false }
        }
        // Keep our palette active until macOS accepts the handoff. Hiding our
        // last window first can give activation to Finder instead.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
            let activated: Bool
            if NSApp.isActive {
                NSApp.yieldActivation(to: app)
                activated = app.activate(from: .current, options: [])
            } else {
                activated = app.activate(options: [])
            }
            guard activated else { return false }
        }
        guard let window = entry.element else { return true }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Some apps restore their previously focused window during activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return raised == .success
    }
}

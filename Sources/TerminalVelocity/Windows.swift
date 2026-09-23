import AppKit
import ApplicationServices

struct WindowSnapshot: @unchecked Sendable {
    var entries: [WindowEntry]
    var notices: [String]
    var completeBrowsers: Set<String> = []
}

enum WindowCatalog {
    static let terminalIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper"
    ]

    static func documentPath(_ element: AXUIElement) -> String? {
        guard let value = Accessibility.attribute(element, kAXDocumentAttribute) else { return nil }
        return localDocumentPath(String(describing: value))
    }

    static func localDocumentPath(_ value: String) -> String? {
        if value.hasPrefix("/") { return (value as NSString).standardizingPath }
        guard let url = URL(string: value), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }

    // Read tab controls, never terminal contents or browser page contents.
    // Apps differ in how deeply they nest the tab strip in their window chrome.
    /// `budget`: how deep to look. Terminals and browsers keep their tabs anywhere in the
    /// chrome; other apps' tab bars sit near the top, and a PDF in Preview is thousands of
    /// elements of nothing (measured 660 ms per round) — a small budget finds the tabs and
    /// stops.
    static func tabs(in window: AXUIElement, budget: Int = 3000, seconds: TimeInterval = 2) -> [(AXUIElement, String)] {
        var found: [(AXUIElement, String)] = []
        var remaining = budget
        let deadline = Date().addingTimeInterval(seconds)
        func walk(_ element: AXUIElement, depth: Int, inTabGroup: Bool) {
            guard depth < 14, remaining > 0, Date() < deadline else { return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let role = Accessibility.attribute(element, kAXRoleAttribute) as? String ?? ""
            if ["AXTextArea", "AXWebArea", "AXTable", "AXOutline"].contains(role) { return }
            let subrole = Accessibility.attribute(element, kAXSubroleAttribute) as? String ?? ""
            let isTab = role == "AXTab" || subrole == "AXTabButton" || (inTabGroup && role == kAXRadioButtonRole)
            if isTab {
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { Accessibility.attribute(element, $0) as? String }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let title { found.append((element, title)) }
                return
            }
            let children = (role == kAXTabGroupRole ? Accessibility.attribute(element, "AXTabs") as? [AXUIElement] : nil)
                ?? Accessibility.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let before = found.count
            for child in children {
                walk(child, depth: depth + 1, inTabGroup: inTabGroup || role == kAXTabGroupRole)
            }
            // A window has one tab strip. Once a container has yielded tabs, the rest of the
            // window is web content and toolbars — stop (85 Chrome windows walked to their
            // budget every round otherwise).
            if found.count > before, found.count > 1 || role == kAXTabGroupRole { remaining = 0 }
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
    static func notificationPreview(_ entry: WindowEntry) -> String? {
        guard let window = entry.element else { return nil }
        // Reading a background tab's owning window would read a different agent.
        if let tab = entry.tab, tabIsSelected(tab) != true { return nil }
        let title = Accessibility.string(window, kAXTitleAttribute)
        if entry.tab == nil, title != entry.title { return nil }
        let text = promptPreview(entry)
        guard Accessibility.string(window, kAXTitleAttribute) == title else { return nil }
        if let tab = entry.tab, tabIsSelected(tab) != true { return nil }
        return AttentionPresentation.excerpt(text)
    }

    static func promptPreview(_ entry: WindowEntry) -> String {
        guard entry.terminal, let window = entry.element else { return "No accessible terminal text is available." }
        if let tab = entry.tab {
            let selected = (Accessibility.attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true
                || (Accessibility.attribute(tab, "AXSelected") as? Bool) == true
            guard selected else { return "This tab is in the background. Open it to read its current prompt." }
        }
        var remaining = 400
        let deadline = Date().addingTimeInterval(1)
        func read(_ node: AXUIElement, depth: Int) -> String? {
            guard remaining > 0, depth < 12, Date() < deadline else { return nil }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.1)
            let role = Accessibility.attribute(node, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return nil }
            if role == kAXTextAreaRole, let value = Accessibility.attribute(node, kAXValueAttribute) as? String, !value.isEmpty {
                return String(value.suffix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for child in Accessibility.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let value = read(child, depth: depth + 1) { return value }
            }
            return nil
        }
        return read(window, depth: 0) ?? "This terminal does not expose readable text. Open it to see the prompt."
    }

    static func position(of entry: WindowEntry?) -> CGPoint? {
        guard let window = entry?.element,
              let raw = Accessibility.attribute(window, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func focusedEntry(app: NSRunningApplication, known: [WindowEntry]) -> WindowEntry? {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let raw = Accessibility.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.1)
        let candidates = known.filter { $0.pid == pid && $0.element.map { CFEqual($0, window) } == true }
        // A selected tab is more specific than its containing window.
        if let selected = candidates.first(where: {
            guard let tab = $0.tab else { return false }
            return (Accessibility.attribute(tab, kAXValueAttribute) as? NSNumber)?.boolValue == true
                || (Accessibility.attribute(tab, "AXSelected") as? Bool) == true
        }) { return selected }
        let title = Accessibility.attribute(window, kAXTitleAttribute) as? String ?? app.localizedName ?? "Application"
        if let matching = candidates.first(where: { !$0.isTab && $0.title == title }) { return matching }
        return WindowEntry(id: "\(pid):focused:\(CFHash(window))", pid: pid,
                           appName: app.localizedName ?? "Application", title: title, icon: app.icon,
                           element: window, minimized: false, hidden: false,
                           terminal: terminalIDs.contains(app.bundleIdentifier ?? ""),
                           browser: BrowserTabs.supported.contains(app.bundleIdentifier ?? ""),
                           documentPath: documentPath(window))
    }

    enum ScanScope { case all, terminals, otherApps }
    static func scan(frontmost: pid_t?, browserTabsEnabled: Bool = false, scope: ScanScope = .all, progress: ((pid_t, String, [WindowEntry]?) -> Void)? = nil) -> WindowSnapshot {
        let running = NSWorkspace.shared.runningApplications
        let audioPIDs: Set<pid_t> = scope == .terminals ? [] : AudioActivity.activeAppPIDs(apps: running)
        let regularApps = running.filter { $0.activationPolicy == .regular }
        let apps = running.filter { app in
            let isTerminal = terminalIDs.contains(app.bundleIdentifier ?? "")
            if scope == .terminals && !isTerminal || scope == .otherApps && isTerminal { return false }
            let ownedHelper = app.activationPolicy != .regular && regularApps.contains { owner in
                guard let path = app.executableURL?.path ?? app.bundleURL?.path, let bundle = owner.bundleURL?.path else { return false }
                return path.hasPrefix(bundle + "/")
            }
            return !ownedHelper && (app.activationPolicy == .regular || audioPIDs.contains(app.processIdentifier)) && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            let firstTerminal = terminalIDs.contains($0.bundleIdentifier ?? "")
            let secondTerminal = terminalIDs.contains($1.bundleIdentifier ?? "")
            if firstTerminal != secondTerminal { return firstTerminal }
            if ($0.processIdentifier == frontmost) != ($1.processIdentifier == frontmost) { return $0.processIdentifier == frontmost }
            return ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }
        var entries: [WindowEntry] = []
        var notices: [String] = []
        var completeBrowsers: Set<String> = []
        for app in apps {
            let pid = app.processIdentifier
            let name = app.localizedName ?? "Application"
            let started = Date()
            defer { JuliaLog.note("scan \(name): \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
            progress?(pid, name, nil)
            let terminal = terminalIDs.contains(app.bundleIdentifier ?? "")
            let browser = BrowserTabs.supported.contains(app.bundleIdentifier ?? "")
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            let windows = Accessibility.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            var appEntries: [WindowEntry] = []
            // Publish scripted destinations before slower AX enrichment (audio,
            // profile association and window controls) walks the browser chrome.
            let scripted = browser && browserTabsEnabled ? BrowserTabs.scan(browserID: app.bundleIdentifier!) : nil
            if let scripted, scripted.error == nil {
                // THE PROFILE ICON IS A LOOKUP, NOT AN HEIRLOOM. Every path that makes a tab entry
                // resolves it from the profile name (the load is cached by Local State's mtime);
                // carrying it over from the previous entry meant a tab first published without
                // one never got one ("i lost the profile icons on the chrome icons in velocity").
                let earlyProfiles = app.bundleIdentifier == "com.google.Chrome" ? ChromeProfileIcon.load() : []
                let earlyTabs = scripted.tabs.map { tab in
                    WindowEntry(id: "\(pid):browser:\(tab.windowID):\(tab.tabID)", pid: pid, appName: name,
                        title: tab.title.isEmpty ? tab.url : tab.title, icon: app.icon, element: nil,
                        minimized: tab.minimized, hidden: app.isHidden, terminal: false,
                        browserTab: tab, browser: true,
                        browserProfile: profileName(windowTitle: tab.windowTitle, appName: name),
                        browserProfileIcon: ChromeProfileIcon.matching(profileName(windowTitle: tab.windowTitle, appName: name), profiles: earlyProfiles))
                }
                progress?(pid, name, earlyTabs)
            }
            let loopStart = Date()
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.15)
                let title = (Accessibility.attribute(window, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let minimized = Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool ?? false
                appEntries.append(WindowEntry(id: "\(pid):window:\(CFHash(window))", pid: pid, appName: name,
                    title: title.isEmpty ? "Untitled window" : title, icon: app.icon,
                    element: window, minimized: minimized, hidden: app.isHidden, terminal: terminal,
                    audio: audioPIDs.contains(pid) ? .appOutput : .none, browser: browser,
                    documentPath: documentPath(window), browserProfile: browser ? profileName(windowTitle: title, appName: name) : nil))
                appEntries.append(contentsOf: ChatProjects.scan(window: window, app: app))
                appEntries.append(contentsOf: ConductorWorkspaces.scan(window: window, app: app))
                appEntries.append(contentsOf: Conversations.scan(window: window, app: app))
                // A tab's audio badge costs an AX read per tab (288 Chrome tabs ≈ 0.6 s a
                // round); only an app that is producing sound can have a playing tab.
                let playing = audioPIDs.contains(pid)
                // A browser's tab strip is near the top of its window and its tabs are
                // already known from scripting; a terminal's tabs can be anywhere.
                let (budget, seconds) = terminal ? (3000, 2.0) : browser ? (700, 0.4) : (400, 0.25)
                for tab in tabs(in: window, budget: budget, seconds: seconds) {
                    appEntries.append(WindowEntry(id: "\(pid):window:\(CFHash(window)):tab:\(CFHash(tab.0))", pid: pid,
                        appName: name, title: tab.1, icon: app.icon, element: window,
                        minimized: minimized, hidden: app.isHidden, terminal: terminal, tab: tab.0,
                        audio: browser ? (playing ? tabAudio(tab.0) : .none) : (playing ? .appOutput : .none), browser: browser,
                        documentPath: documentPath(tab.0), browserProfile: browser ? profileName(windowTitle: title, appName: name) : nil,
                        representedWindowTitle: terminal && tabIsSelected(tab.0) == true && !title.isEmpty ? title : nil))
                }
            }
            if let result = scripted {
                if let error = result.error { notices.append(error) }
                else {
                    completeBrowsers.insert(app.bundleIdentifier!)
                    let accessibleTabs = appEntries.filter { $0.tab != nil }
                    JuliaLog.note("scan \(name): \(accessibleTabs.count) AX tabs for \(result.tabs.count) scripted, \(windows.count) windows; window loop \(Int(Date().timeIntervalSince(loopStart) * 1000)) ms")
                    appEntries.removeAll { $0.tab != nil }
                    let windowAssociations = browserWindowAssociations(windows: appEntries.filter { !$0.isTab && $0.element != nil }, accessibleTabs: accessibleTabs, scriptTabs: result.tabs, appName: name)
                    // ONCE, not per tab: 284 scripted × 280 accessible tabs re-cleaned and
                    // re-filtered each time was the palette's half second.
                    let byCleanTitle = Dictionary(grouping: accessibleTabs, by: { cleanTabTitle($0.title) })
                    let scriptedTitleCount = Dictionary(result.tabs.map { ($0.title, 1) }, uniquingKeysWith: +)
                    let scriptedPerWindow = Dictionary(result.tabs.map { ($0.windowID, 1) }, uniquingKeysWith: +)
                    let byWindow = Dictionary(grouping: accessibleTabs, by: { $0.element.map { CFHash($0) } ?? 0 })
                    for tab in result.tabs {
                        let matches = byCleanTitle[tab.title] ?? []
                        // Never attach one tab's speaker state to a different
                        // duplicate-title tab. Ambiguous matches remain unknown.
                        var match = matches.count == 1 && scriptedTitleCount[tab.title] == 1 ? matches.first : nil
                        let associatedWindow = windowAssociations[tab.windowID]
                        let matchedWindow = associatedWindow?.element
                        if let window = matchedWindow {
                            let windowTabs = byWindow[CFHash(window)] ?? []
                            let scriptedCount = scriptedPerWindow[tab.windowID] ?? 0
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
            progress?(pid, name, appEntries)
        }
        return WindowSnapshot(entries: applyingBrowserAudio(entries) + (scope == .terminals ? [] : installedApps()), notices: notices, completeBrowsers: completeBrowsers)
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

    static func cleanTabTitle(_ title: String) -> String {
        var title = AudioBadge.removingMemoryAnnotation(title)
        for suffix in [" - Audio playing", " - Audio muted", ", Audio playing", ", Audio muted", " - Playing audio"] {
            if title.lowercased().hasSuffix(suffix.lowercased()) { title.removeLast(suffix.count) }
        }
        return title
    }

    static func tabPinned(_ tab: AXUIElement) -> Bool {
        [kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute]
            .compactMap { Accessibility.attribute(tab, $0) as? String }.joined(separator: " ").lowercased().contains("pinned")
    }

    static func tabAudio(_ tab: AXUIElement) -> AudioBadge {
        var labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { Accessibility.attribute(tab, $0) as? String }
        // Safari exposes a Mute/Unmute button in its tab. Only inspect the tab's
        // own controls, never mute buttons in webpage contents.
        for child in (Accessibility.attribute(tab, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(12) {
            labels += [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { Accessibility.attribute(child, $0) as? String }
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
                    .compactMap({ Accessibility.attribute(source, $0) as? String }).first(where: { !$0.isEmpty }) {
                    entry.title = title
                }
            }
            if entry.browser && entry.isTab { entry.audio = entry.tab.map(tabAudio) ?? .none }
            else { entry.audio = pids.contains(entry.pid) ? .appOutput : .none }
            return entry
        }
        return applyingBrowserAudio(updated)
    }

}

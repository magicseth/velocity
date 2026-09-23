import AppKit
import Carbon
import SwiftUI
import ApplicationServices

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = PaletteModel(closedTabs: ClosedTabs())
    lazy var resourceBroker = makeBroker()
    lazy var accessServer = AccessServer(broker: resourceBroker)
    var onboardingWindow: NSWindow?
    var libraryWindow: NSWindow?
    lazy var resourceLibrary = ResourceLibrary(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Velocity/Library/projects.json"))
    var accessWindow: NSWindow?
    var textRequestWindow: NSWindow?
    var textRequestModel: TextRequestModel?
    let updater = AppUpdater()
    var status: NSStatusItem!
    var menuBarFallback: MenuBarFallback?
    var panel: SearchPanel!
    var hotKey: EventHotKeyRef?
    var objectiveHotKey: EventHotKeyRef?
    let objectiveFocus = ObjectiveFocus()
    let attentionNotifications = AttentionNotifications()
    let julia = JuliaLink()
    var attentionCount = 0
    var eventHandler: EventHandlerRef?
    var keyboardMonitor: Any?
    var refreshTimer: Timer?
    var audioTimer: Timer?
    var lastCatalogRefresh = Date.distantPast
    var catalogTimer: Timer?
    var activityTimer: Timer?
    var trackingActivity = false
    var switchingGroup = false
    var lastGroupedWindow: String?
    var lastGroupedPosition: CGPoint?
    var activationObserver: NSObjectProtocol?
    let activityQueue = DispatchQueue(label: "dev.terminalvelocity.activity", qos: .utility)
    var updatingAudio = false
    var snapshotGeneration = 0
    let audioQueue = DispatchQueue(label: "dev.terminalvelocity.audio", qos: .utility)
    var previousApp: NSRunningApplication?
    let terminalCache = TerminalCache()
    var scanning = false
    var scanningTerminals = false
    var scanningChromeMetadata = false
    var chromeMetadataRevision = 0
    let chromeMetadataQueue = DispatchQueue(label: "dev.terminalvelocity.chrome-metadata", qos: .userInitiated)
    let terminalScanner = DispatchQueue(label: "dev.terminalvelocity.terminals", qos: .userInitiated)
    let scanner = DispatchQueue(label: "dev.terminalvelocity.windows", qos: .userInitiated)
    let shortcuts: [(String, UInt32, UInt32)] = [
        ("⌃⌥K", UInt32(controlKey | optionKey), UInt32(kVK_ANSI_K)),
        ("⌘⇧K", UInt32(cmdKey | shiftKey), UInt32(kVK_ANSI_K)),
        ("⌃⌘K", UInt32(controlKey | cmdKey), UInt32(kVK_ANSI_K)),
        ("⌥⇧A", UInt32(optionKey | shiftKey), UInt32(kVK_ANSI_A)),
        ("⌘⇧A", UInt32(cmdKey | shiftKey), UInt32(kVK_ANSI_A)),
        ("⌥ Space", UInt32(optionKey), UInt32(kVK_Space))
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Features.experimentalAgents {
        do {
            if let endpoint = try AIGrouping.importConfiguration(arguments: CommandLine.arguments) { model.aiEndpoint = endpoint }
        } catch { model.message = "AI grouping setup failed: " + error.localizedDescription }
        }
        model.all = terminalCache.load()
        model.filter()
        bootstrapDirectoryReader()
        NSApp.setActivationPolicy(.accessory)
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 510),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Terminal Velocity"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PaletteView(model: model))
        model.activateObjective = { [weak self] item in self?.activateObjective(item) }
        model.restoreObjectiveFocus = { [weak self] in self?.objectiveFocus.restore() }
        model.choose = { [weak self] in self?.choose() }
        model.chooseEntry = { [weak self] entry in self?.choose(entry) }
        model.closeEntry = { [weak self] entry in self?.close(entry) }
        model.cleanup.apply = { [weak self] candidates in self?.cleanUpTabs(candidates) }
        model.inspect = { [weak self] entry in self?.inspect(entry) }
        model.refresh = { [weak self] in self?.refresh() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = "VelocityStatusItem"
        status.button?.image = Branding.menuIcon()
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status.button?.toolTip = "Terminal Velocity — search windows"
        menuBarFallback = MenuBarFallback(status: status)
        menuBarFallback?.menu = { [weak self] in self?.statusMenu() ?? NSMenu() }
        julia.openEntry = { [weak self] entry in self?.choose(entry) }
        julia.notice = { [weak self] text in self?.model.message = text }
        julia.allEntries = { [weak self] in self?.model.all ?? [] }
        julia.foreground = { [weak self] entries, lead in await self?.focusGroup(entries, selected: lead) ?? false }
        attentionNotifications.openAttention = { [weak self] in self?.showAttention() }
        attentionNotifications.openEntry = { [weak self] entry in
            guard let self else { return }
            // A notification click activates Velocity asynchronously. Finish that
            // handoff before yielding to Terminal, or macOS can steal focus back.
            NSApp.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    if NSApp.isActive { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                self.choose(entry)
            }
        }
        attentionNotifications.answerEntry = { [weak self] entry, approval in
            guard let self else { return }
            NSApp.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    if NSApp.isActive { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                guard await self.focusGroup([], selected: entry) else {
                    self.model.message = "Couldn’t reach the terminal. No answer was sent."
                    self.showAttention(); return
                }
                self.panel.orderOut(nil)
                if !AttentionAnswer.send(approval, to: entry) {
                    self.model.message = "The prompt changed or expired. No answer was sent; review it in the terminal."
                }
            }
        }
        attentionNotifications.changed = { [weak self] count, issue in
            guard let self else { return }
            self.attentionCount = count
            // Keep attention changes from expanding the crowded menu bar.
            // The icon dot and tooltip still expose attention and its count.
            self.status.button?.title = ""
            self.status.button?.image = Branding.menuIcon(attention: count > 0)
            self.status.button?.contentTintColor = count > 0 ? .systemOrange : nil
            self.status.button?.toolTip = issue ?? (count > 0 ? "\(count) agents need your input — click to view" : "Terminal Velocity — \(self.model.shortcut)")
            if let issue { self.model.message = issue }
            else { self.updateAccessAttention() }
        }
        attentionNotifications.start(requestAuthorization: UserDefaults.standard.bool(forKey: "onboardingCompleted") && !CommandLine.arguments.contains("--onboarding"))
        let menu = NSMenu()
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(edit)
        let access = NSMenuItem(title: "Access", action: nil, keyEquivalent: "")
        access.submenu = NSMenu(title: "Access")
        let accessSettings = NSMenuItem(title: "Agent Access…", action: #selector(showAgentAccess), keyEquivalent: ",")
        accessSettings.target = self
        access.submenu?.addItem(accessSettings)
        if Features.experimentalAgents {
            let ask = NSMenuItem(title: "Ask Velocity…", action: #selector(showTextRequest), keyEquivalent: "")
            ask.target = self
            access.submenu?.addItem(ask)
            let library = NSMenuItem(title: "Resource Library…", action: #selector(showResourceLibrary), keyEquivalent: "")
            library.target = self; access.submenu?.addItem(library)
        }
        menu.addItem(access)
        NSApp.mainMenu = menu
        installHotkeyHandler()
        registerShortcut((UserDefaults.standard.object(forKey: "shortcut") as? Int) ?? 5)
        if Features.experimentalAgents && RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: 0x54564C43, id: 2), GetApplicationEventTarget(), 0, &objectiveHotKey) != noErr {
            model.message = "Objective shortcut unavailable. Use the menu-bar menu."
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if Features.experimentalAgents && self.matchesCurrentShortcut(event) {
                if !event.isARepeat { self.showTextRequest() }
                return nil
            }
            if self.model.showCleanup {
                if event.keyCode == 53 && !self.model.cleanup.busy { self.model.showCleanup = false; return nil }
                return event
            }
            if self.model.showAIGrouping {
                if event.keyCode == 53 && !self.model.aiLoading { self.model.showAIGrouping = false; return nil }
                return event
            }
            if self.model.objectiveMode {
                if event.keyCode == 53 { self.dismiss(restore: true); return nil }
                if event.keyCode == 125 || event.keyCode == 48 { self.model.moveObjective(flags.contains(.shift) ? -1 : 1); return nil }
                if event.keyCode == 126 { self.model.moveObjective(-1); return nil }
                if event.keyCode == 36 { self.model.openSelectedObjective(); return nil }
                if flags == .command && event.charactersIgnoringModifiers == "d" {
                    let items = self.model.objectiveItems
                    if items.indices.contains(self.model.objectiveSelection) { self.model.markObjective(items[self.model.objectiveSelection], done: true) }
                    return nil
                }
                return event
            }
            if self.model.previewEntry != nil {
                if event.keyCode == 53 { self.model.previewEntry = nil; return nil }
                return event
            }
            if flags == .command && event.charactersIgnoringModifiers == "i" {
                if self.model.results.indices.contains(self.model.selected), self.model.results[self.model.selected].terminal {
                    self.inspect(self.model.results[self.model.selected])
                }
                return nil
            }
            if self.model.editingGroup {
                if event.keyCode == 53 { self.model.editingGroup = false; return nil }
                return event
            }
            if Features.experimentalAgents && flags == .command && event.charactersIgnoringModifiers == "g" {
                if self.model.results.indices.contains(self.model.selected) { self.model.editGroup(self.model.results[self.model.selected]) }
                return nil
            }
            if flags == [.command, .option], let key = event.charactersIgnoringModifiers,
               let number = Int(key), (1...9).contains(number) {
                if self.model.results.indices.contains(number - 1) { self.choose(self.model.results[number - 1]) }
                return nil
            }
            if flags == .command && event.charactersIgnoringModifiers == "/" { self.model.showHelp.toggle(); return nil }
            if event.keyCode == 53 && self.model.showHelp { self.model.showHelp = false; return nil }
            if self.model.showHelp { return event }
            if event.keyCode == 53 { self.dismiss(restore: true); return nil }
            if event.keyCode == 125 { self.model.move(1); return nil }
            if event.keyCode == 126 { self.model.move(-1); return nil }
            if flags == .command && event.charactersIgnoringModifiers == "r" { self.refresh(); return nil }
            return event
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.model.showHelp else { return }
                // A round took 2.5 s and the next began at once: the palette was indexing
                // for as long as it was open. Let a finished round age before the next.
                if self.scanning || Date().timeIntervalSince(self.lastCatalogRefresh) < 8 { return }
                self.refresh()
            }
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudio() }
        }
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, (self.panel.isVisible || self.model.browserTabsEnabled), !self.model.showHelp else { return }
                if !self.panel.isVisible && Date().timeIntervalSince(self.lastCatalogRefresh) < 60 { return }
                self.refresh()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackActivity() }
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackActivity() }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let installed = WindowCatalog.installedApps()
            DispatchQueue.main.async {
                guard let self, self.model.all.isEmpty, !self.scanning else { return }
                self.model.all = installed
                self.model.filter()
            }
        }
        if UserDefaults.standard.bool(forKey: "onboardingCompleted") && !CommandLine.arguments.contains("--onboarding") { show() }
        else { showOnboarding() }
    }

    func trackActivity() {
        guard onboardingWindow?.isVisible != true, !panel.isVisible, !trackingActivity, !switchingGroup, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        trackingActivity = true
        let entries = model.all
        activityQueue.async { [weak self] in
            let entry = WindowCatalog.focusedEntry(app: app, known: entries)
            let position = WindowCatalog.position(of: entry)
            DispatchQueue.main.async {
                guard let self else { return }
                self.trackingActivity = false
                guard !self.panel.isVisible,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let entry else { return }
                if Features.experimentalAgents && (self.lastGroupedWindow != entry.windowKey || self.lastGroupedPosition != position) {
                    self.lastGroupedPosition = position
                    self.lastGroupedWindow = entry.windowKey
                    let companions = WindowGroup.companions(of: entry, groups: self.model.groups, entries: self.model.all)
                    if !companions.isEmpty {
                        Task { @MainActor in _ = await self.focusGroup(companions, selected: entry) }
                    }
                }
                self.model.memory.observe(entry.memoryKey)
                if !self.model.all.contains(where: { $0.memoryKey == entry.memoryKey }) { self.model.all.append(entry) }
                // NOW, for Julia: the window his hands are on (sent once per change, not per tick).
                self.julia.now(entry)
            }
        }
    }

    func installHotkeyHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let objective = identifier.id == 2
            Task { @MainActor in if objective { delegate.switchObjectives() } else { delegate.toggle() } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    func matchesCurrentShortcut(_ event: NSEvent) -> Bool {
        let index = UserDefaults.standard.object(forKey: "shortcut") as? Int ?? 5
        guard shortcuts.indices.contains(index) else { return false }
        let shortcut = shortcuts[index]
        var flags: NSEvent.ModifierFlags = []
        if shortcut.1 & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if shortcut.1 & UInt32(optionKey) != 0 { flags.insert(.option) }
        if shortcut.1 & UInt32(controlKey) != 0 { flags.insert(.control) }
        if shortcut.1 & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return event.keyCode == UInt16(shortcut.2) && event.modifierFlags.intersection([.command, .option, .control, .shift]) == flags
    }

    @discardableResult func registerShortcut(_ requested: Int) -> Bool {
        let index = shortcuts.indices.contains(requested) ? requested : 5
        if hotKey != nil, UserDefaults.standard.object(forKey: "shortcut") as? Int == index { return true }
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcuts[index].2, shortcuts[index].1,
                                        EventHotKeyID(signature: 0x54564C43, id: 1), GetApplicationEventTarget(), 0, &replacement)
        guard result == noErr else {
            model.message = "Shortcut unavailable. Choose another in the menu."
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        model.shortcutRegistered = true
        model.shortcut = shortcuts[index].0
        UserDefaults.standard.set(index, forKey: "shortcut")
        status.button?.toolTip = "Terminal Velocity — \(model.shortcut)"
        return true
    }

    @objc func showTabCleanup() { show(); model.showCleanup = true }

    @objc func showClosedTabs() { show(); model.query = "@closed" }
    @objc func clearClosedTabs() { model.closedTabs.clear(); model.filter(preserveSelection: true) }

    func statusMenu() -> NSMenu {
        let menu = NSMenu()
        add("Search Windows…", #selector(openFromMenuBar), to: menu)
        add("Clean Up Tabs…", #selector(showTabCleanup), to: menu)
        add("Recently Closed Tabs…", #selector(showClosedTabs), to: menu)
        add("Clear Recently Closed Tabs", #selector(clearClosedTabs), to: menu)
        let pending = resourceBroker.requests.filter { $0.status == .pending }.count
        if Features.experimentalAgents {
            add("Ask Velocity…", #selector(showTextRequest), to: menu)
            add("Resource Library…", #selector(showResourceLibrary), to: menu)
        }
        add(pending > 0 ? "Agent Access (\(pending) requests)…" : "Agent Access…", #selector(showAgentAccess), to: menu)
        if Features.experimentalAgents { add("Switch Objectives…  ⌃⌥O", #selector(switchObjectives), to: menu) }
        add("Attention (\(attentionCount))", #selector(showAttention), to: menu)
        add(julia.menuTitle, #selector(toggleJulia), to: menu)
        let notifications = NSMenuItem(title: "Agent Notifications", action: #selector(toggleNotifications), keyEquivalent: "")
        notifications.target = self; notifications.state = attentionNotifications.enabled ? .on : .off
        menu.addItem(notifications)
        add("Test Notification", #selector(testNotification), to: menu)
        add("Notification Settings…", #selector(notificationSettings), to: menu)
        if Features.experimentalAgents { add("Restore Other Windows", #selector(restoreWindows), to: menu) }
        let shortcut = NSMenuItem(title: "Keyboard Shortcut", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for (index, value) in shortcuts.enumerated() {
            let item = NSMenuItem(title: value.0, action: #selector(changeShortcut(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = index == UserDefaults.standard.integer(forKey: "shortcut") ? .on : .off
            choices.addItem(item)
        }
        shortcut.submenu = choices; menu.addItem(shortcut)
        add("Welcome to Velocity…", #selector(showOnboarding), to: menu)
        add("Accessibility Settings…", #selector(accessibility), to: menu)
        add("Enable Chrome & Safari Tabs…", #selector(enableBrowserTabs), to: menu)
        menu.addItem(.separator())
        add("Check for Updates…", #selector(checkForUpdates), to: menu)
        add("Quit Terminal Velocity", #selector(quit), to: menu)
        return menu
    }

    @objc func statusClicked() {
        if let button = status.button {
            statusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    @objc func openFromMenuBar() {
        // Let menu-bar tracking finish before taking focus. A click means open,
        // even if a stale palette still reports itself visible or key.
        DispatchQueue.main.async { [weak self] in self?.show() }
    }

    func add(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    @objc func checkForUpdates() { panel.orderOut(nil); updater.check() }
    @objc func changeShortcut(_ sender: NSMenuItem) {
        guard sender.tag != UserDefaults.standard.integer(forKey: "shortcut") else { return }
        registerShortcut(sender.tag)
    }
    @objc func showAttention() { show() }
    @objc func toggleNotifications() { attentionNotifications.toggle() }
    @objc func testNotification() { attentionNotifications.test() }
    @objc func notificationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
    func observeAttention() {
        let entries = attentionEntries()
        attentionNotifications.observe(entries)
        julia.observe(attention: entries, all: model.all)
    }
    /// What counts as "an agent needs him": the notifier and Julia's board see the same list.
    func attentionEntries() -> [WindowEntry] {
        guard Features.experimentalAgents else { return model.all }
        let doneWindows = Set(model.groups.filter { model.ledger.records[$0.id.uuidString]?.done == true }.flatMap(\.members))
        return model.all.filter { entry in
            if let key = entry.windowKey, doneWindows.contains(key) { return false }
            return model.ledger.records[entry.memoryKey]?.done != true
        }
    }
    @objc func toggleJulia() { julia.toggle() }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { julia.open(url) }
    }
    @objc func accessibility() { model.openAccessibility() }
    @objc func enableBrowserTabs() { model.enableBrowserTabs() }
    @objc func quit() { objectiveFocus.restore(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { objectiveFocus.restore() }
    @objc func restoreWindows() { objectiveFocus.restore() }
    @objc func switchObjectives() {
        guard Features.experimentalAgents else { return }
        if panel.isVisible && model.objectiveMode { model.moveObjective(1); return }
        show()
        model.objectiveQuery = ""
        model.showDoneObjectives = false
        model.objectiveSelection = 0
        model.objectiveMode = true
    }
    func activateObjective(_ item: ObjectiveItem) {
        guard Features.experimentalAgents else { return }
        guard let primary = item.entries.first(where: { $0.attention == .needsInput }) ?? item.entries.first else {
            model.message = "This objective has no open windows."; return
        }
        Task { @MainActor in
            objectiveFocus.restore()
            guard await focusGroup(item.entries, selected: primary) else {
                model.message = "Couldn’t bring every objective window forward. Refresh its windows."; return
            }
            if model.focusObjectives { objectiveFocus.isolate(item.entries, among: model.all) }
            model.ledger.update(item.id) { $0.lastUsed = Date().timeIntervalSince1970 }
            model.currentObjectiveID = item.id
            model.objectWillChange.send()
            panel.orderOut(nil)
        }
    }

    func focusGroup(_ entries: [WindowEntry], selected: WindowEntry) async -> Bool {
        guard !switchingGroup else { return false }
        switchingGroup = true
        let openingMessage = "Opening \(selected.appName)…"
        model.message = openingMessage
        defer {
            switchingGroup = false
            if model.message == openingMessage { model.message = nil }
        }
        var seen: Set<String> = []
        // One raise per WINDOW. A browser tab has no AX window key (its window is known by the
        // browser's own id), so keying on windowKey alone dropped every tab from the group —
        // "double clicking what2do did not open good.pm": the terminal came up, the tabs never
        // got a turn. Each tab keys by its browser window; a tab already chosen for that
        // window carries it.
        let groupKey: (WindowEntry) -> String? = { e in
            e.windowKey ?? e.browserTab.map { "\($0.browserID):\($0.windowID)" }
        }
        let selectedKey = groupKey(selected)
        let companions = entries.filter {
            guard let key = groupKey($0), key != selectedKey, seen.insert(key).inserted else { return false }
            return true
        }
        let result = await FocusSequence.run(companions: companions, selected: selected) { entry in
            guard await WindowCatalog.focus(entry) else { JuliaLog.note("focus FAILED: \(entry.appName) “\(entry.title.prefix(40))” tab=\(entry.browserTab != nil)"); return false }
            JuliaLog.note("focus ok: \(entry.appName) “\(entry.title.prefix(40))”")
            // Activation is asynchronous and can take longer than a fixed 180 ms,
            // especially when an app is hidden or switching Spaces.
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
            // Browser scripting already selected and verified the stable tab before
            // activation. There is no delayed AX raise or second selection to wait for.
            if entry.browserTab != nil { return true }
            // Let the delayed window raise complete before selecting its tab.
            try? await Task.sleep(for: .milliseconds(140))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
            let selectedTab: Bool
            if let conversation = entry.conversation, let window = entry.element {
                // Preserve activation until the handoff above succeeds, then remove
                // the floating palette before hit-testing the destination sidebar.
                panel.orderOut(nil)
                selectedTab = Conversations.select(conversation, window: window)
            } else if let project = entry.chatProject, let window = entry.element {
                if project.mode == "Workspace" {
                    selectedTab = ConductorWorkspaces.select(project, window: window)
                } else {
                    selectedTab = await ChatProjects.select(project, window: window)
                }
            } else {
                selectedTab = await WindowCatalog.selectFocusedTab(entry)
            }
            return selectedTab && NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid
        }
        if result.selectedFocused {
            lastGroupedWindow = selected.windowKey
            lastGroupedPosition = WindowCatalog.position(of: selected)
            if !result.companionsFocused { model.message = "Opened your selection; some related windows couldn’t be brought forward." }
        }
        return result.selectedFocused
    }
    @objc func toggle() {
        if PalettePresentation.shouldDismiss(visible: panel.isVisible, key: panel.isKeyWindow, active: NSApp.isActive) {
            if Features.experimentalAgents { showTextRequest() }
            else { dismiss(restore: true) }
        } else if Features.experimentalAgents, textRequestWindow?.isKeyWindow == true {
            textRequestModel?.invalidate()
            textRequestWindow?.orderOut(nil)
            show()
        } else { show() }
    }

    func show() {
        model.liveMatchingActive = true
        model.showAIGrouping = false
        model.objectiveMode = false
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = frontmost }
        model.previewEntry = nil
        model.showCleanup = false
        model.showHelp = false
        model.editingGroup = false
        model.openAllApps()
        model.filter()
        model.message = nil
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 340, y: max(frame.minY, frame.midY - 180)))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // Reinstall the view so the search field receives focus on every opening.
        panel.contentView = NSHostingView(rootView: PaletteView(model: model))
        refresh()
    }

    /// The fast path's tab list, with everything only the scan knows poured in by tab id:
    /// the AX element and tab, audio, the profile and its icon, pinned. A tab the scan did
    /// not see keeps what it had; a tab only the scan saw is gone (the list is newer).
    static func enrich(_ latest: [WindowEntry], from scanned: [WindowEntry]) -> [WindowEntry] {
        let byID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return latest.map { entry in
            guard let s = byID[entry.id] else { return entry }
            var e = entry
            if e.element == nil { e.element = s.element }
            if e.tab == nil { e.tab = s.tab }
            if e.audio == .none { e.audio = s.audio }
            if e.browserProfile == nil || e.browserProfile == "Profile unavailable" { e.browserProfile = s.browserProfile ?? e.browserProfile }
            if e.browserProfileIcon == nil { e.browserProfileIcon = s.browserProfileIcon }
            if !e.browserPinned { e.browserPinned = s.browserPinned }
            return e
        }
    }

    func refreshChromeMetadata() {
        guard model.browserTabsEnabled, !scanningChromeMetadata,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return }
        scanningChromeMetadata = true
        chromeMetadataQueue.async { [weak self] in
            let result = BrowserTabs.scan(browserID: "com.google.Chrome")
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanningChromeMetadata = false
                guard result.error == nil, !app.isTerminated else {
                    self.model.closedTabs.observe([], complete: false, launch: app.launchDate)
                    return
                }
                let prior = Dictionary(self.model.all.filter { $0.pid == app.processIdentifier }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let profiles = ChromeProfileIcon.load()   // cached by Local State's mtime
                let entries = result.tabs.map { tab in
                    let id = "\(app.processIdentifier):browser:\(tab.windowID):\(tab.tabID)"
                    let old = prior[id]
                    let profile = WindowCatalog.profileName(windowTitle: tab.windowTitle, appName: app.localizedName ?? "Google Chrome") ?? old?.browserProfile
                    return WindowEntry(id: id, pid: app.processIdentifier, appName: app.localizedName ?? "Google Chrome",
                        title: tab.title.isEmpty ? tab.url : tab.title, icon: app.icon, element: old?.element,
                        minimized: tab.minimized, hidden: app.isHidden, terminal: false, tab: old?.tab,
                        browserTab: tab, audio: old?.audio ?? .none, browser: true,
                        browserProfile: profile,
                        // A lookup, never inherited: an entry born without an icon stayed without one.
                        browserProfileIcon: ChromeProfileIcon.matching(profile, profiles: profiles) ?? old?.browserProfileIcon, browserPinned: old?.browserPinned ?? false)
                }
                self.chromeMetadataRevision += 1
                self.snapshotGeneration += 1
                self.model.all.removeAll { $0.pid == app.processIdentifier }
                self.model.all.append(contentsOf: entries)
                self.model.closedTabs.observe(self.model.all, complete: true, launch: app.launchDate)
                self.model.filter(preserveSelection: true)
            }
        }
    }

    func refreshTerminals() {
        guard !scanningTerminals else { return }
        scanningTerminals = true
        let pid = previousApp?.processIdentifier
        terminalScanner.async { [weak self] in
            let snapshot = WindowCatalog.scan(frontmost: pid, scope: .terminals) { appPID, _, entries in
                guard let entries else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.snapshotGeneration += 1
                    self.model.all.removeAll { $0.pid == appPID }
                    self.model.all.append(contentsOf: entries)
                    self.model.filter(preserveSelection: true)
                }
            }
            self?.terminalCache.save(snapshot.entries)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotGeneration += 1
                self.model.all.removeAll { $0.terminal && $0.launchURL == nil }
                self.model.all.append(contentsOf: snapshot.entries)
                self.model.filter(preserveSelection: true)
                self.observeAttention()
                self.scanningTerminals = false
                self.model.loading = self.scanning
            }
        }
    }

    func refresh() {
        guard onboardingWindow?.isVisible != true else { return }
        model.trusted = AXIsProcessTrusted()
        guard model.trusted, !model.cleanup.busy else { return }
        refreshTerminals()
        refreshChromeMetadata()
        model.loading = true
        guard !scanning else { return }
        lastCatalogRefresh = Date()
        scanning = true
        model.loading = true
        let pid = previousApp?.processIdentifier
        let browserTabsEnabled = model.browserTabsEnabled
        let chromeRevision = chromeMetadataRevision
        scanner.async { [weak self] in
            let snapshot = WindowCatalog.scan(frontmost: pid, browserTabsEnabled: browserTabsEnabled, scope: .otherApps) { appPID, name, entries in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.model.scanningApp = name
                    // THE FAST PATH LANDED MID-SCAN: its tab list is newer, but the scan's
                    // enrichment (the AX element, audio, profile) is the only source of those —
                    // every palette opening starts both, and the fast fetch always finished
                    // first, so the enrichment was discarded every time ("no profile, and no
                    // audio playing chip"). Keep the newer list; pour the enrichment into it.
                    if self.chromeMetadataRevision != chromeRevision,
                       self.model.all.contains(where: { $0.pid == appPID && $0.browserTab?.browserID == "com.google.Chrome" }) {
                        guard let entries else { return }
                        let latest = self.model.all.filter { $0.pid == appPID }
                        let merged = Self.enrich(latest, from: entries)
                        self.snapshotGeneration += 1
                        self.model.all.removeAll { $0.pid == appPID }
                        self.model.all.append(contentsOf: merged)
                        self.model.filter(preserveSelection: true)
                        return
                    }
                    if let entries {
                        self.snapshotGeneration += 1
                        let prior = Dictionary(self.model.all.filter { $0.pid == appPID }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        let entries = entries.map { entry in
                            guard entry.browserTab != nil, entry.element == nil, let old = prior[entry.id] else { return entry }
                            var enriched = entry
                            enriched.audio = old.audio
                            enriched.browserProfile = entry.browserProfile ?? old.browserProfile
                            enriched.browserProfileIcon = entry.browserProfileIcon ?? old.browserProfileIcon
                            return enriched
                        }
                        self.model.all.removeAll { $0.pid == appPID }
                        self.model.all.append(contentsOf: entries)
                        self.model.filter(preserveSelection: true)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // Other-app completion must not overwrite newer terminal results.
                var snapshot = snapshot
                snapshot.entries += self.model.all.filter { $0.terminal && $0.launchURL == nil }
                if self.chromeMetadataRevision != chromeRevision,
                   let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
                    // Same rule at completion: the newer list, carrying the scan's enrichment.
                    let latest = self.model.all.filter { $0.pid == chrome.processIdentifier }
                    let scanned = snapshot.entries.filter { $0.pid == chrome.processIdentifier }
                    snapshot.entries.removeAll { $0.pid == chrome.processIdentifier }
                    snapshot.entries += Self.enrich(latest, from: scanned)
                }
                self.snapshotGeneration += 1
                if self.chromeMetadataRevision == chromeRevision {
                    self.model.closedTabs.observe(snapshot.entries, complete: snapshot.completeBrowsers.contains("com.google.Chrome"),
                        launch: NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.launchDate)
                }
                self.model.all = snapshot.entries
                self.resourceBroker.reconcile(snapshot.entries)
                self.model.cleanup.observe(snapshot.entries)
                self.model.reconnectGroups()
                self.model.observeObjectives()
                self.observeAttention()
                self.model.browserNotice = snapshot.notices.isEmpty ? nil : snapshot.notices.joined(separator: " · ")
                self.model.filter(preserveSelection: true)
                self.model.loading = self.scanningTerminals
                self.model.scanningApp = self.scanningTerminals ? "terminals" : nil
                self.scanning = false
            }
        }
    }

    func refreshAudio() {
        guard onboardingWindow?.isVisible != true else { return }
        guard model.trusted, !updatingAudio else { return }
        updatingAudio = true
        let generation = snapshotGeneration
        let entries = model.all
        audioQueue.async { [weak self] in
            let updated = WindowCatalog.updatingAudio(entries)
            DispatchQueue.main.async {
                guard let self else { return }
                self.updatingAudio = false
                guard self.snapshotGeneration == generation else { return }
                self.model.all = updated
                self.model.observeObjectives()
                self.observeAttention()
                self.model.filter(preserveSelection: true)
            }
        }
    }

    func inspect(_ entry: WindowEntry) {
        model.previewEntry = entry
        model.previewText = "Reading terminal text…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = WindowCatalog.promptPreview(entry)
            DispatchQueue.main.async {
                guard let self, self.model.previewEntry?.id == entry.id else { return }
                self.model.previewText = text
            }
        }
    }

    func close(_ entry: WindowEntry) {
        guard entry.canClose, model.closingEntries.insert(entry.id).inserted else { return }
        Task { @MainActor in
            defer { model.closingEntries.remove(entry.id) }
            let accepted = await CloseResult.close(entry)
            if !accepted { model.message = "Couldn’t close that result. Open it in its app to close it." }
            // Do not optimistically remove a result: its app may be asking to save
            // a document or confirm ending running terminal processes.
            try? await Task.sleep(for: .milliseconds(250))
            refresh()
        }
    }

    func choose() {
        guard let entry = model.resultState.selectedEntry else { return }
        choose(entry)
    }

    func choose(_ entry: WindowEntry) {
        if let cached = entry.cachedTerminal {
            guard let live = cached.resolve() else {
                model.all.removeAll { $0.id == entry.id }
                model.filter(preserveSelection: true)
                model.message = "That cached terminal changed or closed. Live results are refreshing."
                refresh()
                return
            }
            choose(live)
            return
        }
        if let closed = entry.closedTab {
            if closed.reopen() {
                model.closedTabs.remove(closed.id)
                model.filter(preserveSelection: true)
                panel.orderOut(nil)
                refresh()
            } else {
                let alert = NSAlert()
                alert.messageText = "Reopen in Chrome’s current profile?"
                alert.informativeText = "The original window could not be reopened. This will open the saved address in Chrome’s current profile, which may differ from \(closed.profile ?? "the original profile")."
                alert.addButton(withTitle: "Reopen")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn,
                      ClosedTabs.validURL(closed.url), let url = URL(string: closed.url),
                      let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
                NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: .init()) { [weak self] app, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if app != nil && error == nil {
                            self.model.closedTabs.remove(closed.id)
                            self.model.filter(preserveSelection: true)
                            self.panel.orderOut(nil)
                            self.refresh()
                        } else { self.model.message = "Couldn’t reopen this tab. It remains in Recently Closed." }
                    }
                }
            }
            return
        }
        if let url = entry.launchURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if app != nil && error == nil {
                        self.model.memory.observe(entry.memoryKey)
                        self.model.all.removeAll { $0.id == entry.id }
                        self.panel.orderOut(nil)
                    } else {
                        self.model.message = "Couldn’t launch \(entry.appName). \(error?.localizedDescription ?? "Try again.")"
                    }
                }
            }
            return
        }
        let companions = Features.experimentalAgents ? WindowGroup.companions(of: entry, groups: model.groups, entries: model.all) : []
        Task { @MainActor in
            if await focusGroup(companions, selected: entry) {
                if var tab = entry.browserTab {
                    tab.isActive = true
                    model.cleanup.activity.observe([tab])
                }
                model.memory.observe(entry.memoryKey)
                panel.orderOut(nil)
            } else {
                model.message = "Couldn’t open the selected window or tab. Choose it again after refresh."
                NSApp.activate()
                panel.makeKeyAndOrderFront(nil)
                refresh()
            }
        }
    }

    func dismiss(restore: Bool) {
        model.liveMatchingActive = false
        model.liveMatcher.cancel()
        if restore, let previousApp {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        panel.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        // A queued resign notification from the previous handoff must not hide a
        // palette that has already regained focus through the global shortcut.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.model.liveMatchingActive = false
            self.model.liveMatcher.cancel()
            self.panel.orderOut(nil)
        }
    }
}

@main struct TerminalVelocity {
    @MainActor static func main() {
        // Debugging the answers watcher: what does Velocity read as the last exchange in a transcript?
        if let i = CommandLine.arguments.firstIndex(of: "--last-exchange"), CommandLine.arguments.indices.contains(i + 1) {
            if let e = AnswerWatcher.parse(CommandLine.arguments[i + 1]) {
                print("source=\(e.source) done=\(e.done) cwd=\(e.cwd ?? "-") id=\(e.externalId)\nQ: \(e.question.prefix(200))\nA: \((e.answer ?? "(none yet)").prefix(300))")
            } else { print("no exchange found in that transcript") }
            return
        }
        // The incremental path the watcher actually takes after the first read: from a known offset.
        if let i = CommandLine.arguments.firstIndex(of: "--last-exchange-from"), CommandLine.arguments.indices.contains(i + 2) {
            let known = UInt64(CommandLine.arguments[i + 2])
            if let (e, offset) = AnswerWatcher.read(CommandLine.arguments[i + 1], from: known) {
                print("source=\(e.source) done=\(e.done) cwd=\(e.cwd ?? "-") id=\(e.externalId) questionAt=\(offset)\nQ: \(e.question.prefix(200))\nA: \((e.answer ?? "(none yet)").prefix(300))")
            } else { print("no exchange found from offset \(known.map(String.init) ?? "nil")") }
            return
        }
        // Debugging media: what does Velocity see as Now Playing, and does its ⏯ press take?
        if CommandLine.arguments.contains("--media-probe") {
            print("somethingIsPlaying (CoreAudio):", JuliaHands.somethingIsPlaying())
            print("nowPlayingRate (MediaRemote, Apple-signed only):", JuliaHands.nowPlayingRate().map { "\($0)" } ?? "nil")
            return
        }
        // Debugging Open: which terminal would Velocity raise for a conversation's folder?
        if let i = CommandLine.arguments.firstIndex(of: "--find-terminal"), CommandLine.arguments.indices.contains(i + 1) {
            let entries = WindowCatalog.scan(frontmost: nil).entries
            for e in entries where e.terminal { print("  \(JuliaWorkspace.signature(e))  ←  \(e.title.prefix(70))  [doc: \(e.documentPath ?? "-")]") }
            if let e = JuliaLink.terminal(inFolder: CommandLine.arguments[i + 1], in: entries) { print("→ would raise: \(e.title.prefix(80))") } else { print("→ nothing found") }
            return
        }
        if CommandLine.arguments.contains("--list-windows") {
            guard AXIsProcessTrusted() else {
                print("Accessibility permission is required. Open the app and follow its setup screen.")
                exit(2)
            }
            for entry in WindowCatalog.scan(frontmost: nil).entries { print("\(entry.appName)\t\(entry.title)") }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

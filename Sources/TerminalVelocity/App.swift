import AppKit
import Carbon
import SwiftUI
import ApplicationServices

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = PaletteModel()
    let updater = AppUpdater()
    var status: NSStatusItem!
    var panel: SearchPanel!
    var hotKey: EventHotKeyRef?
    var objectiveHotKey: EventHotKeyRef?
    let objectiveFocus = ObjectiveFocus()
    let attentionNotifications = AttentionNotifications()
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
    var scanning = false
    let scanner = DispatchQueue(label: "dev.terminalvelocity.windows", qos: .userInitiated)
    let shortcuts: [(String, UInt32, UInt32)] = [
        ("⌃⌥K", UInt32(controlKey | optionKey), UInt32(kVK_ANSI_K)),
        ("⌘⇧K", UInt32(cmdKey | shiftKey), UInt32(kVK_ANSI_K)),
        ("⌃⌘K", UInt32(controlKey | cmdKey), UInt32(kVK_ANSI_K)),
        ("⌥⇧A", UInt32(optionKey | shiftKey), UInt32(kVK_ANSI_A)),
        ("⌘⇧A", UInt32(cmdKey | shiftKey), UInt32(kVK_ANSI_A))
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Features.experimentalAgents {
        do {
            if let endpoint = try AIGrouping.importConfiguration(arguments: CommandLine.arguments) { model.aiEndpoint = endpoint }
        } catch { model.message = "AI grouping setup failed: " + error.localizedDescription }
        }
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
        attentionNotifications.openAttention = { [weak self] in self?.showAttention() }
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
        }
        attentionNotifications.start()
        let menu = NSMenu()
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
        installHotkeyHandler()
        registerShortcut((UserDefaults.standard.object(forKey: "shortcut") as? Int) ?? 4)
        if Features.experimentalAgents && RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: 0x54564C43, id: 2), GetApplicationEventTarget(), 0, &objectiveHotKey) != noErr {
            model.message = "Objective shortcut unavailable. Use the menu-bar menu."
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
                guard let self, self.panel.isVisible, !self.model.trusted, AXIsProcessTrusted() else { return }
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
        show()
    }

    func trackActivity() {
        guard !panel.isVisible, !trackingActivity, !switchingGroup, AXIsProcessTrusted(),
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

    func registerShortcut(_ requested: Int) {
        let index = shortcuts.indices.contains(requested) ? requested : 4
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcuts[index].2, shortcuts[index].1,
                                        EventHotKeyID(signature: 0x54564C43, id: 1), GetApplicationEventTarget(), 0, &replacement)
        guard result == noErr else {
            model.message = "Shortcut unavailable. Choose another in the menu."
            return
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        model.shortcut = shortcuts[index].0
        UserDefaults.standard.set(index, forKey: "shortcut")
        status.button?.toolTip = "Terminal Velocity — \(model.shortcut)"
    }

    @objc func showTabCleanup() { show(); model.showCleanup = true }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            add("Search Windows…", #selector(openFromMenuBar), to: menu)
            add("Clean Up Tabs…", #selector(showTabCleanup), to: menu)
            if Features.experimentalAgents { add("Switch Objectives…  ⌃⌥O", #selector(switchObjectives), to: menu) }
            add("Attention (\(attentionCount))", #selector(showAttention), to: menu)
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
            add("Accessibility Settings…", #selector(accessibility), to: menu)
            add("Enable Chrome & Safari Tabs…", #selector(enableBrowserTabs), to: menu)
            menu.addItem(.separator())
            add("Check for Updates…", #selector(checkForUpdates), to: menu)
            add("Quit Terminal Velocity", #selector(quit), to: menu)
            // Present directly without temporarily replacing the status item's
            // menu/action routing, which can interfere with subsequent clicks.
            if let button = status.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
        } else { openFromMenuBar() }
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
        guard Features.experimentalAgents else { attentionNotifications.observe(model.all); return }
        let doneWindows = Set(model.groups.filter { model.ledger.records[$0.id.uuidString]?.done == true }.flatMap(\.members))
        attentionNotifications.observe(model.all.filter { entry in
            if let key = entry.windowKey, doneWindows.contains(key) { return false }
            return model.ledger.records[entry.memoryKey]?.done != true
        })
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
        defer { switchingGroup = false }
        var seen: Set<String> = []
        let companions = entries.filter {
            guard let key = $0.windowKey, key != selected.windowKey, seen.insert(key).inserted else { return false }
            return true
        }
        let result = await FocusSequence.run(companions: companions, selected: selected) { entry in
            guard WindowCatalog.focus(entry) else { return false }
            // Activation is asynchronous and can take longer than a fixed 180 ms,
            // especially when an app is hidden or switching Spaces.
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
            // Let the delayed window raise complete before selecting its tab.
            try? await Task.sleep(for: .milliseconds(140))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
            let selectedTab: Bool
            if let project = entry.chatProject, let window = entry.element {
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
            dismiss(restore: true)
        } else { show() }
    }

    func show() {
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

    func refresh() {
        model.trusted = AXIsProcessTrusted()
        guard model.trusted, !scanning, !model.cleanup.busy else { return }
        lastCatalogRefresh = Date()
        scanning = true
        model.loading = true
        let pid = previousApp?.processIdentifier
        let browserTabsEnabled = model.browserTabsEnabled
        scanner.async { [weak self] in
            let snapshot = WindowCatalog.scan(frontmost: pid, browserTabsEnabled: browserTabsEnabled)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotGeneration += 1
                self.model.all = snapshot.entries
                self.model.cleanup.observe(snapshot.entries)
                self.model.reconnectGroups()
                self.model.observeObjectives()
                self.observeAttention()
                self.model.browserNotice = snapshot.notices.isEmpty ? nil : snapshot.notices.joined(separator: " · ")
                self.model.filter(preserveSelection: true)
                self.model.loading = false
                self.scanning = false
            }
        }
    }

    func refreshAudio() {
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
            self.panel.orderOut(nil)
        }
    }
}

@main struct TerminalVelocity {
    @MainActor static func main() {
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

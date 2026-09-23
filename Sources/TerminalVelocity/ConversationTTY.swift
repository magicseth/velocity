import AppKit
import Darwin
import Foundation

/// THE EXACT TAB A CONVERSATION LIVES IN. A folder is not an identity: two agents in
/// ~/Projects/convexos (a Claude session and a Codex session) share one folder, and a
/// reply addressed by folder went to the wrong one ("it didn't make it back to this
/// terminal"). What is unique is the terminal device the agent is attached to:
///
///   transcript session id → agent process → its tty → the Terminal tab on that tty.
///
/// Claude Code keeps `~/.claude/sessions/<pid>.json` (pid ↔ sessionId). Codex keeps no
/// pid; its process is the codex in that folder whose start is nearest before the
/// session began. Terminal.app tells us each tab's tty (Apple Events; one permission).
enum ConversationTTY {
    /// "ttys001" for the process behind this transcript, or nil when it cannot be pinned.
    static func tty(source: String, sessionId: String, cwd: String?, startedAt: Double) -> String? {
        guard let pid = source.hasPrefix("Claude") ? claudePid(sessionId) : codexPid(cwd: cwd, startedAt: startedAt) else { return nil }
        return tty(of: pid)
    }

    static func claudePid(_ sessionId: String) -> pid_t? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (j["sessionId"] as? String) == sessionId, let pid = j["pid"] as? Int32 else { continue }
            return kill(pid, 0) == 0 ? pid : nil
        }
        return nil
    }

    /// The codex process working in that folder that started closest before the session.
    static func codexPid(cwd: String?, startedAt: Double) -> pid_t? {
        guard let cwd else { return nil }
        var best: (pid: pid_t, start: Double)?
        for pid in allPids() {
            guard let name = processName(pid), name == "node" || name == "codex" else { continue }
            guard processArgs(pid).contains(where: { $0.hasSuffix("/codex") || $0 == "codex" }) else { continue }
            guard processCwd(pid) == cwd, let start = processStart(pid), start <= startedAt + 5 else { continue }
            if best == nil || start > best!.start { best = (pid, start) }
        }
        return best?.pid
    }

    static func tty(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32.max else { return nil }
        guard let name = devname(dev_t(info.e_tdev), mode_t(S_IFCHR)) else { return nil }
        return String(cString: name)
    }

    // MARK: Terminal.app tabs by tty

    struct Tab { let windowName: String; let windowIndex: Int; let tabIndex: Int; let tty: String; let selected: Bool; var windowID: CGWindowID = 0 }

    /// Every Terminal.app tab with its tty. One Apple Events round trip; nil when Terminal
    /// is not running or he has not allowed Velocity to control it.
    static func terminalTabs() -> [Tab] {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").contains(where: { !$0.isTerminated }) else { return [] }
        // ONE round trip, not sixty: "tty of every tab of every window" comes back as one
        // nested list in a single Apple Event. Asking per tab (tty, selected, name — three
        // events × twenty tabs) took 3.5 s of every Open ("can clicking open be a lot
        // faster? it takes seconds now").
        let source = """
        tell application "Terminal"
            set ttys to tty of every tab of every window
            set sels to selected of every tab of every window
            set names to name of every window
            set ids to id of every window
            set out to ""
            repeat with wi from 1 to count of ttys
                set wt to item wi of ttys
                set ws to item wi of sels
                repeat with ti from 1 to count of wt
                    set sel to "0"
                    if item ti of ws then set sel to "1"
                    set out to out & wi & "\t" & ti & "\t" & (item ti of wt) & "\t" & sel & "\t" & (item wi of ids) & "\t" & (item wi of names) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue else {
            JuliaLog.note("terminalTabs: AppleScript failed: \((err?[NSAppleScript.errorMessage] as? String) ?? "?")"); return []
        }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let wi = Int(f[0]), let ti = Int(f[1]) else { return nil }
            // Terminal's window `id` IS the window server's id — the one key both sides share.
            return Tab(windowName: f[5], windowIndex: wi, tabIndex: ti, tty: (f[2] as NSString).lastPathComponent, selected: f[3] == "1", windowID: CGWindowID(f[4]) ?? 0)
        }
    }

    /// A title with its blinking parts removed — "[ ! ] Action Required" alternates with
    /// "[ . ]", and a working agent's ◐◑ spins — so a name read a moment apart still matches.
    /// The accessibility title also leads with the folder's PATH ("~/Projects/x — …") where
    /// Terminal's window name leads with its NAME ("x — …"): the first segment is reduced to
    /// its last path component on both sides.
    static func steady(_ title: String) -> String {
        var parts = title.components(separatedBy: " — ")
        if let first = parts.first, first.contains("/") { parts[0] = (first as NSString).lastPathComponent }
        return parts.joined(separator: " — ")
            .replacingOccurrences(of: #"\[\s*[!.]\s*\]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[✳◐◑]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The tty a catalog entry (a Terminal tab) sits on — the inverse of `entry(onTTY:)`:
    /// its window is the group whose selected tab's title is the window's name, its
    /// position in that group is the script's tab index.
    static func tty(of entry: WindowEntry, in entries: [WindowEntry], tabs: [Tab]? = nil) -> String? {
        guard entry.isTab, let element = entry.element, let wid = WindowRaise.windowID(of: element) else { return nil }
        let all = tabs ?? terminalTabs()
        // THE WINDOW BY ITS SERVER ID, not by the catalog's key (two windows once hashed alike)
        // and not by name (which blinks). Its tabs, in the tab bar's order, are the catalog
        // entries whose window element is this window; the entry's position is the tab.
        let wtabs = all.filter { $0.windowID == wid }
        guard !wtabs.isEmpty else { return nil }
        // One tab in the window: that is it (the catalog lists a one-tab window twice — as
        // the window and as its tab — so a position would be off by one).
        if wtabs.count == 1 { return wtabs[0].tty }
        let siblings = entries.filter { $0.pid == entry.pid && $0.isTab && $0.element.map { WindowRaise.windowID(of: $0) == wid } == true }
        guard let index = siblings.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if let tab = wtabs.first(where: { $0.tabIndex == index + 1 }) { return tab.tty }
        JuliaLog.note("tty(of:) unresolved: window \(wid) has \(wtabs.count) tabs, catalog has \(siblings.count), index \(index)")
        return nil
    }

    /// The tab's screen, by tty — one Apple Event, any window, front or not.
    static func contents(ofTTY tty: String) -> String? {
        let source = """
        tell application "Terminal"
            set found to contents of (tabs of windows whose tty is "/dev/\(tty)")
            repeat with w in found
                repeat with t in w
                    return t as text
                end repeat
            end repeat
            return ""
        end tell
        """
        var err: NSDictionary?
        guard let text = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// The WindowEntry (a Terminal tab) sitting on that tty. Windows are matched by name
    /// (the window's title is its selected tab's title), tabs by position within the window.
    static func entry(onTTY tty: String, in entries: [WindowEntry]) -> WindowEntry? {
        let all = terminalTabs()
        guard let tab = all.first(where: { $0.tty == tty }) else { JuliaLog.note("tty \(tty): not among \(all.count) Terminal tabs"); return nil }
        let terminalPids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").map(\.processIdentifier))
        let same: (String, String) -> Bool = { a, b in let x = steady(a), y = steady(b); return x == y || x.hasPrefix(y) || y.hasPrefix(x) }
        // The catalog lists a tabbed window as its TABS (each with the window's key). The
        // window's name is its selected tab's title, so the group holding a tab with that
        // title is the window; the tab at the script's position is the one.
        let groups = Dictionary(grouping: entries.filter { terminalPids.contains($0.pid) && $0.isTab }, by: { $0.windowKey ?? "" })
        if let group = groups.values.first(where: { g in g.contains { same($0.title, tab.windowName) } }) {
            let sorted = group   // catalog order = tab order (both walk the tab bar left to right)
            if sorted.indices.contains(tab.tabIndex - 1) { return sorted[tab.tabIndex - 1] }
            if let selected = sorted.first(where: { same($0.title, tab.windowName) }), tab.selected { return selected }
        }
        // A single-tab window is listed as a plain window.
        let windows = entries.filter { terminalPids.contains($0.pid) && $0.element != nil && !$0.isTab }
        if let window = windows.first(where: { same($0.title, tab.windowName) }) { return window }
        // Not in the catalog (another Space, most often): no entry — the tty in the handle
        // still finds the tab when it is time to type. Not an error.
        return nil
    }

    /// A typing target for that tty that needs NO catalog entry: Terminal itself selects the
    /// tab and orders its window front (it can, on any Space — the catalog only sees the
    /// current one), Velocity then activates Terminal the one way the background is allowed
    /// to (Launch Services, see JuliaLink.raise). Returns the tab's window name for the log.
    /// Is the tab on that tty the selected tab of Terminal's FRONT window right now? The
    /// keystrokes go to the key window; "Terminal is frontmost" is not enough — with
    /// Terminal already in front on another window, his words landed in the wrong one.
    static func isFront(tty: String) -> Bool {
        let source = """
        tell application "Terminal"
            if (count of windows) is 0 then return "none"
            return tty of selected tab of front window
        end tell
        """
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue == "/dev/" + tty
    }

    /// DID THE WORDS LAND? The selected tab's contents, asked once of Terminal; true when
    /// the tail of what was typed shows in the last lines. Bounded: the caller races this
    /// against a short deadline (an Apple Event can stall) and treats "no answer" as not
    /// upgraded — `keys-posted` stays the method, never a claim beyond what was seen.
    static func promptEchoes(tail: String) -> Bool {
        let want = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard want.count >= 3 else { return false }
        let source = """
        tell application "Terminal"
            if (count of windows) is 0 then return ""
            return contents of selected tab of front window
        end tell
        """
        var err: NSDictionary?
        guard let contents = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue else { return false }
        let recent = String(contents.suffix(1200)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return recent.contains(want.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
    }

    /// The ttys of shells sitting in that folder right now — a `terminal.open` receipt is
    /// a NEW one of these appearing (`tty-appeared`), not the open() call returning.
    static func shellTTYs(inFolder dir: String) -> Set<String> {
        let want = (dir as NSString).standardizingPath
        var out: Set<String> = []
        for pid in allPids() {
            guard let name = processName(pid), ["zsh", "bash", "fish", "sh", "login", "-zsh", "-bash"].contains(name) else { continue }
            guard let cwd = processCwd(pid), (cwd as NSString).standardizingPath == want, let tty = tty(of: pid) else { continue }
            out.insert(tty)
        }
        return out
    }

    /// `select` selects the tab and orders its window front inside Terminal, returning the
    /// window's id (the window server's), or nil when the tab moved.
    static func target(onTTY tty: String) -> (entry: WindowEntry, select: () -> CGWindowID?)? {
        guard let tab = terminalTabs().first(where: { $0.tty == tty }),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first(where: { !$0.isTerminated }) else { return nil }
        let entry = WindowEntry(id: "tty:" + tty, pid: app.processIdentifier, appName: app.localizedName ?? "Terminal", title: tab.windowName,
                                icon: nil, element: nil, minimized: false, hidden: app.isHidden, terminal: true)
        let select: () -> CGWindowID? = {
            let source = """
            tell application "Terminal"
                set w to window \(tab.windowIndex)
                set t to tab \(tab.tabIndex) of w
                if (tty of t) is not "/dev/\(tty)" then return "moved"
                set selected of t to true
                set miniaturized of w to false
                set index of w to 1
                try
                    set frontmost of w to true
                end try
                return "ok:" & (id of w)
            end tell
            """
            var err: NSDictionary?
            let r = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue ?? ""
            guard r.hasPrefix("ok:"), let wid = UInt32(r.dropFirst(3)) else {
                JuliaLog.note("select tab on \(tty): \(r.isEmpty ? ((err?[NSAppleScript.errorMessage] as? String) ?? "?") : r)"); return nil
            }
            return CGWindowID(wid)
        }
        return (entry, select)
    }

    // MARK: process facts (libproc; no shelling out)

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(got))).filter { $0 > 0 }
    }
    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
    private static func processCwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    }
    private static func processStart(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) * 1000 + Double(info.pbi_start_tvusec) / 1000
    }
    private static func processArgs(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        guard size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        let parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        // parts[0] = exec path, then padding empties, then argv...
        var args = Array(parts.dropFirst().drop(while: \.isEmpty))
        if args.count > argc { args = Array(args.prefix(argc)) }
        return args
    }
}

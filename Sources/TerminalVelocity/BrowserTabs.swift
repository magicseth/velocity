import AppKit

struct BrowserTab: Sendable {
    let browserID: String
    let windowID: Int
    let tabID: Int // Chrome's stable ID; Safari's snapshot index.
    let title: String
    let url: String
    let minimized: Bool
    let windowTitle: String
    let index: Int
    var isActive: Bool = true
    var loading: Bool = true
    var historyEligible: Bool = false
}

enum BrowserTabs {
    private static let scanLock = NSLock()
    static let supported: Set<String> = ["com.google.Chrome", "com.apple.Safari"]

    static func scan(browserID: String) -> (tabs: [BrowserTab], error: String?) {
        guard supported.contains(browserID) else { return ([], nil) }
        scanLock.lock()
        defer { scanLock.unlock() }
        let safari = browserID == "com.apple.Safari"
        let source = scanSource(browserID: browserID)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return ([], "Browser tab script could not be created") }
        let t0 = Date()
        let result = script.executeAndReturnError(&error)
        JuliaLog.note("browser scan \(browserID): \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(result.numberOfItems) tabs")
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let name = safari ? "Safari" : "Chrome"
            return ([], code == -1743 ? "Allow \(name) in Privacy & Security → Automation" : "\(name) tab lookup failed (\(code)); showing accessible tabs")
        }
        var tabs: [BrowserTab] = []
        guard result.numberOfItems > 0 else { return ([], nil) }
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index), row.numberOfItems == 10,
                  let title = row.atIndex(3)?.stringValue,
                  let url = row.atIndex(4)?.stringValue else { continue }
            tabs.append(BrowserTab(browserID: browserID, windowID: Int(row.atIndex(1)!.int32Value),
                tabID: Int(row.atIndex(2)!.int32Value), title: title, url: url,
                minimized: row.atIndex(5)?.booleanValue ?? false,
                windowTitle: row.atIndex(6)?.stringValue ?? "", index: Int(row.atIndex(7)?.int32Value ?? 0),
                isActive: row.atIndex(8)?.booleanValue ?? true, loading: row.atIndex(9)?.booleanValue ?? true,
                historyEligible: row.atIndex(10)?.booleanValue ?? false))
        }
        return (tabs, nil)
    }

    static func scanSource(browserID: String) -> String {
        precondition(supported.contains(browserID))
        let safari = browserID == "com.apple.Safari"
        if !safari {
            return """
            with timeout of 5 seconds
                tell application id "com.google.Chrome"
                    set output to {}
                    set windowIDs to id of every window
                    set windowNames to name of every window
                    set windowMinimizedStates to minimized of every window
                    set windowModes to mode of every window
                    set activeIndices to active tab index of every window
                    set allTabIDs to id of every tab of every window
                    set allTabTitles to title of every tab of every window
                    set allTabURLs to URL of every tab of every window
                    set allTabLoading to loading of every tab of every window
                    if windowIDs is not (id of every window) or allTabIDs is not (id of every tab of every window) then error "Tabs changed during lookup"
                    repeat with i from 1 to count of windowIDs
                        set windowID to item i of windowIDs
                        set windowName to item i of windowNames
                        set windowMinimized to item i of windowMinimizedStates
                        set normalWindow to (item i of windowModes) is "normal"
                        set activeIndex to item i of activeIndices
                        set tabIDs to item i of allTabIDs
                        set tabTitles to item i of allTabTitles
                        set tabURLs to item i of allTabURLs
                        set tabLoading to item i of allTabLoading
                        if (count of tabTitles) is not (count of tabIDs) or (count of tabURLs) is not (count of tabIDs) or (count of tabLoading) is not (count of tabIDs) then error "Tabs changed during lookup"
                        repeat with n from 1 to count of tabIDs
                            set end of output to {windowID, item n of tabIDs, item n of tabTitles, item n of tabURLs, windowMinimized, windowName, n, n is activeIndex, item n of tabLoading, normalWindow}
                        end repeat
                    end repeat
                    return output
                end tell
            end timeout
            """
        }
        return """
        with timeout of 5 seconds
            tell application id "\(browserID)"
                set output to {}
                repeat with w in windows
                    set tabNumber to 0
                    repeat with t in tabs of w
                        set tabNumber to tabNumber + 1
                        set end of output to {id of w as integer, \(safari ? "tabNumber" : "id of t as integer"), \(safari ? "name" : "title") of t as text, URL of t as text, \(safari ? "miniaturized" : "minimized") of w, name of w as text, tabNumber, tabNumber is (\(safari ? "index of current tab" : "active tab index") of w), \(safari ? "false" : "loading of t"), \(safari ? "false" : "mode of w is \"normal\"")}
                    end repeat
                end repeat
                return output
            end tell
        end timeout
        """
    }

    static func select(_ tab: BrowserTab, requireUnchanged: Bool = false) async -> Bool {
        guard supported.contains(tab.browserID) else { return false }
        return await runSelectionScript(selectionSource(tab, requireUnchanged: requireUnchanged))
    }

    // Isolate AppleScript from the UI thread and from in-process catalog scans.
    // Output is a single boolean; never pass titles through a shell.
    static func runSelectionScript(_ source: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            defer { deadline.cancel() }
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus == 0 && String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }.value
    }

    static func selectionSource(_ tab: BrowserTab, requireUnchanged: Bool = false) -> String {
        precondition(supported.contains(tab.browserID))
        let source: String
        if tab.browserID == "com.google.Chrome" {
            source = """
            tell application id "com.google.Chrome"
                repeat with attempt from 1 to 2
                    set candidates to {}
                    if attempt is 1 then
                        try
                            set end of candidates to window id \(tab.windowID)
                        end try
                    else
                        repeat with otherWindow in windows
                            if (id of otherWindow as integer) is not \(tab.windowID) then set end of candidates to contents of otherWindow
                        end repeat
                    end if
                    repeat with w in candidates
                        try
                            try
                                if (id of tab \(max(1, tab.index)) of w as integer) is \(tab.tabID) then
                                    \(requireUnchanged ? "if URL of tab " + String(max(1, tab.index)) + " of w is not " + quote(tab.url) + " or title of tab " + String(max(1, tab.index)) + " of w is not " + quote(tab.title) + " then return false" : "")
                                    set active tab index of w to \(max(1, tab.index))
                                    set minimized of w to false
                                    set index of w to 1
                                    return (id of active tab of w as integer) is \(tab.tabID)
                                end if
                            end try
                            set tabIDs to id of every tab of w
                            repeat with n from 1 to count of tabIDs
                                if (item n of tabIDs as integer) is \(tab.tabID) then
                                    \(requireUnchanged ? "if URL of tab n of w is not " + quote(tab.url) + " or title of tab n of w is not " + quote(tab.title) + " then return false" : "")
                                    set minimized of w to false
                                    set active tab index of w to n
                                    set index of w to 1
                                    return (id of active tab of w as integer) is \(tab.tabID)
                                end if
                            end repeat
                        end try
                    end repeat
                end repeat
                return false
            end tell
            """
        } else {
            // Safari has no persistent scripting tab ID. Validate the original
            // slot; if tabs were reordered, only accept a unique title+URL match.
            source = """
            tell application id "com.apple.Safari"
                set w to window id \(tab.windowID)
                set wantedURL to \(quote(tab.url))
                set wantedTitle to \(quote(tab.title))
                set chosen to 0
                if (count of tabs of w) ≥ \(tab.tabID) then
                    set t to tab \(tab.tabID) of w
                    if URL of t is wantedURL and name of t is wantedTitle then set chosen to \(tab.tabID)
                end if
                if chosen is 0 then
                    set hits to {}
                    repeat with n from 1 to count of tabs of w
                        set t to tab n of w
                        if URL of t is wantedURL and name of t is wantedTitle then set end of hits to n
                    end repeat
                    if (count of hits) is not 1 then return false
                    set chosen to item 1 of hits
                end if
                set miniaturized of w to false
                set current tab of w to tab chosen of w
                set index of w to 1
                return true
            end tell
            """
        }
        return "with timeout of 8 seconds\n\(source)\nend timeout"
    }

    static func close(_ tab: BrowserTab) -> Bool {
        guard supported.contains(tab.browserID) else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: closingSource(tab))?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    static func closingSource(_ tab: BrowserTab) -> String {
        if tab.browserID == "com.google.Chrome" {
            return """
            with timeout of 5 seconds
                tell application id "com.google.Chrome"
                    repeat with w in windows
                        repeat with n from 1 to count of tabs of w
                            if (id of tab n of w as integer) is \(tab.tabID) then
                                if URL of tab n of w is not \(quote(tab.url)) or title of tab n of w is not \(quote(tab.title)) then return false
                                close tab n of w
                                return true
                            end if
                        end repeat
                    end repeat
                    return false
                end tell
            end timeout
            """
        }
        // Safari retains its validated index/unique-match logic.
        return selectionSource(tab).components(separatedBy: "\n").compactMap { line -> String? in
            let command = line.trimmingCharacters(in: .whitespaces)
            if ["set minimized of w to false", "set miniaturized of w to false", "set index of w to 1"].contains(command) { return nil }
            if command == "set active tab index of w to n" { return "close tab n of w" }
            if command == "set current tab of w to tab chosen of w" { return "close tab chosen of w" }
            return line
        }.joined(separator: "\n")
    }

    static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

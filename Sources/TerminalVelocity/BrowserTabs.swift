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
}

enum BrowserTabs {
    static let supported: Set<String> = ["com.google.Chrome", "com.apple.Safari"]

    static func scan(browserID: String) -> (tabs: [BrowserTab], error: String?) {
        guard supported.contains(browserID) else { return ([], nil) }
        let safari = browserID == "com.apple.Safari"
        let source = scanSource(browserID: browserID)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return ([], "Browser tab script could not be created") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let name = safari ? "Safari" : "Chrome"
            return ([], code == -1743 ? "Allow \(name) in Privacy & Security → Automation" : "\(name) tab lookup failed (\(code)); showing accessible tabs")
        }
        var tabs: [BrowserTab] = []
        guard result.numberOfItems > 0 else { return ([], nil) }
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index), row.numberOfItems == 7,
                  let title = row.atIndex(3)?.stringValue,
                  let url = row.atIndex(4)?.stringValue else { continue }
            tabs.append(BrowserTab(browserID: browserID, windowID: Int(row.atIndex(1)!.int32Value),
                tabID: Int(row.atIndex(2)!.int32Value), title: title, url: url,
                minimized: row.atIndex(5)?.booleanValue ?? false,
                windowTitle: row.atIndex(6)?.stringValue ?? "", index: Int(row.atIndex(7)?.int32Value ?? 0)))
        }
        return (tabs, nil)
    }

    static func scanSource(browserID: String) -> String {
        precondition(supported.contains(browserID))
        let safari = browserID == "com.apple.Safari"
        return """
        with timeout of 5 seconds
            tell application id "\(browserID)"
                set output to {}
                repeat with w in windows
                    set tabNumber to 0
                    repeat with t in tabs of w
                        set tabNumber to tabNumber + 1
                        try
                            set end of output to {id of w as integer, \(safari ? "tabNumber" : "id of t as integer"), \(safari ? "name" : "title") of t as text, URL of t as text, \(safari ? "miniaturized" : "minimized") of w, name of w as text, tabNumber}
                        end try
                    end repeat
                end repeat
                return output
            end tell
        end timeout
        """
    }

    static func select(_ tab: BrowserTab) -> Bool {
        guard supported.contains(tab.browserID) else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: selectionSource(tab))?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    static func selectionSource(_ tab: BrowserTab) -> String {
        precondition(supported.contains(tab.browserID))
        let source: String
        if tab.browserID == "com.google.Chrome" {
            source = """
            tell application id "com.google.Chrome"
                repeat with w in windows
                    repeat with n from 1 to count of tabs of w
                        if (id of tab n of w as integer) is \(tab.tabID) then
                            set minimized of w to false
                            set active tab index of w to n
                            set index of w to 1
                            return true
                        end if
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
        return "with timeout of 3 seconds\n\(source)\nend timeout"
    }

    static func close(_ tab: BrowserTab) -> Bool {
        guard supported.contains(tab.browserID) else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: closingSource(tab))?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    static func closingSource(_ tab: BrowserTab) -> String {
        // Reuse stable Chrome IDs and Safari's validated index/unique-match logic.
        selectionSource(tab).components(separatedBy: "\n").compactMap { line -> String? in
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

import AppKit

struct DeliveryRecipient: Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String
    let accountID: String
    let adapterID: String
    let adapterName: String
    var selectionKey: String { adapterID + ":" + id }
}
struct LinkDeliveryPreview: Identifiable {
    let id: UUID
    let resource: ManagedResource
    let url: String
    let recipient: DeliveryRecipient
    let created: Date
    // Only the exact URL is sent. No model-authored message or script is executable.
    var body: String { url }
}
enum MessageLinks {
    static func validURL(_ raw: String) -> Bool {
        guard raw.count <= 8000, !raw.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }),
              let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
    @MainActor static func recipients(matching query: String) throws -> [DeliveryRecipient] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100 else { throw AccessError.unsupported }
        let source = lookupSource(query)
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            throw AIGrouping.Failure(code == -1743 ? "Allow Velocity to control Messages in System Settings → Privacy & Security → Automation." : "Messages couldn’t resolve that recipient. Try their full name. (\(code))")
        }
        guard let result, result.numberOfItems > 0 else { return [] }
        var recipients: [DeliveryRecipient] = []
        for i in 1...result.numberOfItems {
            guard let row = result.atIndex(i), row.numberOfItems == 4,
                  let id = row.atIndex(1)?.stringValue, let name = row.atIndex(2)?.stringValue,
                  let handle = row.atIndex(3)?.stringValue, let account = row.atIndex(4)?.stringValue,
                  !id.isEmpty, !handle.isEmpty, !account.isEmpty else { continue }
            let recipient = DeliveryRecipient(id: id, name: name, handle: handle, accountID: account, adapterID: "com.apple.MobileSMS", adapterName: "Messages")
            if !recipients.contains(where: { $0.id == id }) { recipients.append(recipient) }
        }
        return recipients
    }
    static func lookupSource(_ query: String) -> String {
        return """
        with timeout of 10 seconds
            tell application id "com.apple.MobileSMS"
                set output to {}
                set matches to every participant whose name contains \(BrowserTabs.quote(query)) or full name contains \(BrowserTabs.quote(query))
                repeat with p in matches
                    if (count of output) is greater than or equal to 40 then error "Too many matches; use a full name."
                    try
                        if service type of account of p is iMessage then
                            set displayName to full name of p
                            if displayName is missing value or displayName is "" then set displayName to name of p
                            set end of output to {id of p as text, displayName as text, handle of p as text, id of account of p as text}
                        end if
                    end try
                end repeat
                return output
            end tell
        end timeout
        """
    }
    static func sourceIsCurrent(_ entry: WindowEntry) -> Bool {
        guard let tab = entry.browserTab else { return false }
        let scan = BrowserTabs.scan(browserID: tab.browserID)
        guard scan.error == nil else { return false }
        return scan.tabs.filter { $0.windowID == tab.windowID && $0.tabID == tab.tabID && $0.title == tab.title && $0.url == tab.url }.count == 1
    }
    static func sendSource(_ preview: LinkDeliveryPreview) -> String {
        let person = preview.recipient
        return """
        with timeout of 15 seconds
            tell application id "com.apple.MobileSMS"
                set matches to every participant whose id is \(BrowserTabs.quote(person.id))
                if (count of matches) is not 1 then return false
                set p to item 1 of matches
                if handle of p is not \(BrowserTabs.quote(person.handle)) then return false
                if id of account of p is not \(BrowserTabs.quote(person.accountID)) then return false
                if service type of account of p is not iMessage then return false
                set displayName to full name of p
                if displayName is missing value or displayName is "" then set displayName to name of p
                if displayName is not \(BrowserTabs.quote(person.name)) then return false
                send \(BrowserTabs.quote(preview.body)) to p
                return true
            end tell
        end timeout
        """
    }
    @MainActor static func send(_ preview: LinkDeliveryPreview) throws -> Bool {
        guard preview.recipient.adapterID == "com.apple.MobileSMS", validURL(preview.url) else { throw AccessError.unsupported }
        var error: NSDictionary?
        let result = NSAppleScript(source: sendSource(preview))?.executeAndReturnError(&error)
        if error != nil {
            // An Apple event timeout may happen after Messages accepted the send.
            // Never automatically retry or report definite failure in that case.
            throw AIGrouping.Failure("Messages did not confirm the send. Check the conversation before trying again; it may have been sent.")
        }
        return result?.booleanValue == true
    }
}

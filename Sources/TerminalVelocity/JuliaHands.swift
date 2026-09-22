import AppKit
import CoreGraphics
import Foundation

// THE HANDS: typing into a conversation, and quieting the room while he talks.
//
// Seth: "a press and hold voice button on the results that sends the transcript and
// hits enter to the agents that responded to me (it should pause any youtube videos
// i'm watching while i'm talking)". Julia's face records and transcribes; Velocity —
// the Mac's hands — puts the words where they go and holds the videos.
//
//   velocity://type?sig=…&handle=…&text=…&enter=1   type into THAT conversation's tab
//   velocity://media?pause=1 | resume=1              pause playing web videos; resume the
//                                                    ones it paused
enum JuliaHands {
    /// Keystrokes go ONLY to the terminal Velocity itself brought forward, and only
    /// once it is frontmost: never into whatever happens to have focus.
    @MainActor static func type(_ text: String, enter: Bool, into entry: WindowEntry, after raised: @escaping () async -> Void) async -> Bool {
        guard entry.terminal, !text.isEmpty, text.count <= 4000 else { return false }
        await raised()
        for _ in 0..<40 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
        try? await Task.sleep(for: .milliseconds(120))
        // Unicode keystrokes: the terminal receives the words exactly, whatever the layout.
        let src = CGEventSource(stateID: .combinedSessionState)
        for chunk in text.chunked(20) {
            let chars = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
            chars.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
        if enter {
            try? await Task.sleep(for: .milliseconds(80))
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// PAUSE ALL MEDIA ("netflix should pause too, all media really"): every playing
    /// <video> or <audio> in any Chrome/Safari tab, and the native players — Music,
    /// Spotify, TV, QuickTime. Each is marked so `resume` restarts only what Velocity
    /// paused, never something he had paused himself.
    static func pauseVideos() -> String? { runMedia(pause: true) }
    static func resumeVideos() -> String? { runMedia(pause: false) }

    /// THE FALLBACK THAT NEEDS NO SETTING. Chrome refuses JavaScript from Apple Events
    /// until he turns it on (View ▸ Developer ▸ Allow JavaScript from Apple Events), so
    /// the precise per-tab pause can fail. Velocity already knows which windows are
    /// PLAYING AUDIO; if any is, the system Play/Pause key pauses the Now Playing app
    /// (YouTube in Chrome, Netflix, Music, Spotify all register). Remembered, so the
    /// release presses it again only if this pressed it.
    private static var pressedPlayPause = false
    static func pauseByKey(ifAnyPlaying entries: [WindowEntry]) {
        guard entries.contains(where: { $0.audio == .playing || $0.audio == .appOutput }) else { return }
        playPauseKey(); pressedPlayPause = true
    }
    static func resumeByKey() {
        guard pressedPlayPause else { return }
        pressedPlayPause = false; playPauseKey()
    }
    private static func playPauseKey() {
        // NX_KEYTYPE_PLAY = 16, delivered as a system-defined event (what the keyboard's ⏯ sends).
        for down in [true, false] {
            let flags: UInt = down ? 0xA00 : 0xB00
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 8, data1: Int((16 << 16) | (down ? 0xA : 0xB) << 8), data2: -1) else { continue }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static var pausedNativePlayers: Set<String> = []
    private static let pauseJS = "document.querySelectorAll('video,audio').forEach(function(v){if(!v.paused&&!v.ended){v.pause();v.dataset.juliaPaused='1'}})"
    private static let resumeJS = "document.querySelectorAll('video[data-julia-paused],audio[data-julia-paused]').forEach(function(v){v.play();delete v.dataset.juliaPaused})"

    /// Returns a problem to show him, or nil. Chrome must allow JavaScript from Apple
    /// Events (View ▸ Developer); Safari, "Allow JavaScript from Apple Events" in Develop.
    private static func runMedia(pause: Bool) -> String? {
        let js = (pause ? pauseJS : resumeJS).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var problems: [String] = []
        let browsers = """
        if application "Google Chrome" is running then
          tell application "Google Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                try
                  execute t javascript "\(js)"
                end try
              end repeat
            end repeat
          end tell
        end if
        if application "Safari" is running then
          tell application "Safari"
            repeat with w in windows
              repeat with t in tabs of w
                try
                  do JavaScript "\(js)" in t
                end try
              end repeat
            end repeat
          end tell
        end if
        """
        var error: NSDictionary?
        NSAppleScript(source: browsers)?.executeAndReturnError(&error)
        if let error, let msg = error[NSAppleScript.errorMessage] as? String { problems.append("browsers: \(msg.prefix(80))") }
        // Native players: pause only if playing; resume only what we paused.
        let players: [(name: String, playing: String, pause: String, play: String)] = [
            ("Music", "player state is playing", "pause", "play"),
            ("Spotify", "player state is playing", "pause", "play"),
            ("TV", "player state is playing", "pause", "play"),
            ("QuickTime Player", "(count of (documents whose playing is true)) > 0", "pause every document", "play every document"),
        ]
        for p in players {
            let source = pause
                ? "if application \"\(p.name)\" is running then\n tell application \"\(p.name)\"\n if \(p.playing) then\n \(p.pause)\n return \"paused\"\n end if\n end tell\nend if\nreturn \"\""
                : (pausedNativePlayers.contains(p.name) ? "if application \"\(p.name)\" is running then tell application \"\(p.name)\" to \(p.play)\nreturn \"\"" : nil)
            guard let source else { continue }
            var err: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if pause, out?.stringValue == "paused" { pausedNativePlayers.insert(p.name) }
            if !pause { pausedNativePlayers.remove(p.name) }
            if let err, let msg = err[NSAppleScript.errorMessage] as? String, !msg.contains("isn’t running") { problems.append("\(p.name): \(msg.prefix(60))") }
        }
        return problems.isEmpty ? nil : problems.joined(separator: " · ")
    }
}

private extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []; var i = startIndex
        while i < endIndex { let j = index(i, offsetBy: n, limitedBy: endIndex) ?? endIndex; out.append(String(self[i..<j])); i = j }
        return out
    }
}

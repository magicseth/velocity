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
    /// `raised` brings the exact terminal forward and returns whether it IS in front; false
    /// means nothing is typed — the words never go to whichever window happened to be key.
    @MainActor static func type(_ text: String, enter: Bool, into entry: WindowEntry, after raised: @escaping () async -> Bool) async -> Bool {
        guard entry.terminal, !text.isEmpty, text.count <= 4000 else { return false }
        guard await raised() else { return false }
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
            // A CLEAR GAP BEFORE RETURN. Claude Code (and other TUIs) take a fast burst of
            // characters as a paste, and a Return inside the burst becomes a newline in
            // the paste, not a submit — his words sat in the prompt unsent. 80 ms was
            // inside the burst; a third of a second is a separate keypress.
            try? await Task.sleep(for: .milliseconds(350))
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// PAUSE ALL MEDIA ("netflix should pause too, all media really"), fast first:
    ///   1. the ⏯ key, if the system says something is playing — instant, needs no setting;
    ///   2. then, off the main thread, the precise path: every playing <video>/<audio> in
    ///      any Chrome/Safari tab (Chrome only once he allows JavaScript from Apple
    ///      Events; checked once, remembered), and the native players that are INSTALLED
    ///      AND RUNNING — naming an absent app makes macOS ask "Where is Spotify?" and
    ///      block, which is exactly what happened.
    /// Everything paused is remembered so resume restarts only that.
    static func pauseVideos() -> String? { runMedia(pause: true) }
    static func resumeVideos() -> String? { runMedia(pause: false) }

    private static var pressedPlayPause = false
    /// IS ANYTHING PLAYING? Ask CoreAudio which processes are outputting sound right now
    /// (public API; Velocity's audio badge already uses it). The system's Now Playing
    /// info was the obvious question, but macOS answers it only for Apple-signed
    /// processes now — a probe script saw Netflix at rate 1.0 while the app saw nothing,
    /// so the key was never pressed. Sound coming out of a media app is a plain fact.
    static func somethingIsPlaying() -> Bool {
        // Any process but our own: a browser's sound comes out of a HELPER process that is
        // not an NSRunningApplication, so filtering to apps found nothing.
        let loud = AudioActivity.activeAppPIDs(apps: NSWorkspace.shared.runningApplications)
        return !loud.subtracting([getpid()]).isEmpty
    }
    static func pauseByKey(ifAnyPlaying entries: [WindowEntry]) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard somethingIsPlaying() || entries.contains(where: { $0.audio == .playing || $0.audio == .appOutput }) else { return }
            playPauseKey(); pressedPlayPause = true
        }
    }
    static func resumeByKey() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard pressedPlayPause else { return }
            pressedPlayPause = false
            // No "is it still paused?" check: Chrome keeps its audio stream open while
            // paused, so CoreAudio said "playing" and the release never pressed play.
            playPauseKey()
        }
    }
    private static func playPauseKey() {
        // NX_KEYTYPE_PLAY = 16, delivered as a system-defined event (what the keyboard's ⏯ sends).
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((16 << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// The system's Now Playing playback rate (1 = playing, 0 = paused), or nil if
    /// unknown. MediaRemote is private; this reads one number and is a personal app.
    private typealias GetNowPlaying = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    static func nowPlayingRate() -> Double? {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(lib, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        let get = unsafeBitCast(sym, to: GetNowPlaying.self)
        let sem = DispatchSemaphore(value: 0); var rate: Double?
        get(DispatchQueue.global(qos: .userInitiated)) { info in
            rate = info.isEmpty ? nil : (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0)
            sem.signal()
        }
        return sem.wait(timeout: .now() + 0.8) == .success ? rate : nil
    }

    private static var pausedNativePlayers: Set<String> = []
    private static var chromeJSDisabledUntil = Date.distantPast
    private static let pauseJS = "document.querySelectorAll('video,audio').forEach(function(v){if(!v.paused&&!v.ended){v.pause();v.dataset.juliaPaused='1'}})"
    private static let resumeJS = "document.querySelectorAll('video[data-julia-paused],audio[data-julia-paused]').forEach(function(v){v.play();delete v.dataset.juliaPaused})"
    private static let players: [(name: String, bundle: String, playing: String, pause: String, play: String)] = [
        ("Music", "com.apple.Music", "player state is playing", "pause", "play"),
        ("Spotify", "com.spotify.client", "player state is playing", "pause", "play"),
        ("TV", "com.apple.TV", "player state is playing", "pause", "play"),
        ("QuickTime Player", "com.apple.QuickTimePlayerX", "(count of (documents whose playing is true)) > 0", "pause every document", "play every document"),
    ]
    private static func running(_ bundle: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }
    private static func tabsSource(app: String, verb: String, js: String) -> String {
        let action = verb.replacingOccurrences(of: "JS", with: js)
        return "tell application \"\(app)\"\n repeat with w in windows\n  repeat with t in tabs of w\n   try\n    \(action)\n   end try\n  end repeat\n end repeat\nend tell"
    }

    /// Returns a problem to show him, or nil.
    private static func runMedia(pause: Bool) -> String? {
        let js = (pause ? pauseJS : resumeJS).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var problems: [String] = []
        func run(_ source: String) -> String? {
            var err: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let msg = err?[NSAppleScript.errorMessage] as? String { return "!" + msg }
            return out?.stringValue ?? ""
        }
        if running("com.google.Chrome") {
            if Date() > chromeJSDisabledUntil, let r = run("tell application \"Google Chrome\" to execute active tab of front window javascript \"1\""), r.contains("turned off") {
                chromeJSDisabledUntil = Date().addingTimeInterval(600)
                problems.append("Chrome: JavaScript from Apple Events is turned off")
            }
            if Date() > chromeJSDisabledUntil, let r = run(tabsSource(app: "Google Chrome", verb: "execute t javascript \"JS\"", js: js)), r.hasPrefix("!") { problems.append("Chrome: " + r.dropFirst().prefix(60)) }
        }
        if running("com.apple.Safari"), let r = run(tabsSource(app: "Safari", verb: "do JavaScript \"JS\" in t", js: js)), r.hasPrefix("!") { problems.append("Safari: " + r.dropFirst().prefix(60)) }
        for p in players where running(p.bundle) {
            if pause {
                let r = run("tell application \"\(p.name)\"\n if \(p.playing) then\n  \(p.pause)\n  return \"paused\"\n end if\nend tell\nreturn \"\"")
                if r == "paused" { pausedNativePlayers.insert(p.name) }
                if let r, r.hasPrefix("!") { problems.append("\(p.name): " + r.dropFirst().prefix(60)) }
            } else if pausedNativePlayers.contains(p.name) {
                pausedNativePlayers.remove(p.name)
                _ = run("tell application \"\(p.name)\" to \(p.play)")
            }
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

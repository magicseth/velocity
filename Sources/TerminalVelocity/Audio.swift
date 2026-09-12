import AppKit
import CoreAudio

enum AudioBadge: String, Sendable {
    case none, playing, muted, appOutput
    var label: String {
        switch self {
        case .none: return ""
        case .playing: return "Playing audio"
        case .muted: return "Muted"
        case .appOutput: return "App audio"
        }
    }
    var symbol: String { self == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill" }

    static func removingMemoryAnnotation(_ label: String) -> String {
        // Chrome appends this accessibility-only suffix after its audio state.
        // Match a measured size at the end, not arbitrary page-title keywords.
        label.replacingOccurrences(of: #" - Memory usage - [0-9][0-9.,]*\s+(?:bytes|[KMGT]B)$"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func fromTabMetadata(_ labels: [String]) -> AudioBadge {
        let labels = labels.map { removingMemoryAnnotation($0).lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if labels.contains(where: {
            $0.hasSuffix(" - audio muted") || $0.hasSuffix(", audio muted") ||
            $0 == "this tab's audio is being muted." || $0 == "this tab's audio is being muted" ||
            $0 == "unmute tab" || $0 == "unmute this tab"
        }) { return .muted }
        if labels.contains(where: {
            $0.hasSuffix(" - audio playing") || $0.hasSuffix(", audio playing") ||
            $0.hasSuffix(" - playing audio") || $0 == "this tab is playing audio." ||
            $0 == "this tab is playing audio" || $0 == "mute tab" || $0 == "mute this tab"
        }) { return .playing }
        return .none
    }
}

enum AudioActivity {
    // This reads output-stream activity, not audio samples. A running output
    // stream can contain silence; this is deliberately called "App audio".
    static func activeAppPIDs(apps: [NSRunningApplication]) -> Set<pid_t> {
        guard #available(macOS 14.2, *) else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !processes.isEmpty else { return [] }
        let result = processes.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        var active = Set<pid_t>()
        for process in processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
            guard number(process, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pidValue = number(process, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: pidValue)
            active.insert(pid)
            let bundle = bundleID(process)
            let processApp = NSRunningApplication(processIdentifier: pid)
            let helperPath = processApp?.executableURL?.path ?? processApp?.bundleURL?.path
            for app in apps where app.activationPolicy == .regular {
                let bundleMatches = bundle != nil && bundle == app.bundleIdentifier
                let nestedHelper = helperPath.map { path in
                    app.bundleURL.map { path.hasPrefix($0.path + "/") } ?? false
                } ?? false
                if bundleMatches || nestedHelper { active.insert(app.processIdentifier) }
            }
        }
        return active
    }

    private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

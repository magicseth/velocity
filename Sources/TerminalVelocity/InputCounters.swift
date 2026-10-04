import AppKit
import CoreAudio

/// What his hands did since the last focus report — counts only, never which keys. Read from
/// the window server's own event counters (no event tap, no extra permission) and the default
/// input device's "running somewhere" flag (the mic is live in some app).
@MainActor final class InputCounters {
    static let shared = InputCounters()
    private var lastKeys = InputCounters.count(.keyDown)
    private var lastClicks = InputCounters.count(.leftMouseDown) + InputCounters.count(.rightMouseDown)
    private var micSec: Double = 0

    private static func count(_ type: CGEventType) -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
    }
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func sampleMic(seconds: Double) { if Self.micLive() { micSec += seconds } }

    /// Counters since the previous take, and seconds since the last input.
    func take() -> [String: Any] {
        let keys = Self.count(.keyDown), clicks = Self.count(.leftMouseDown) + Self.count(.rightMouseDown)
        let out: [String: Any] = ["keys": Int(keys &- lastKeys), "clicks": Int(clicks &- lastClicks), "micSec": Int(micSec), "idleSec": Int(Self.idleSeconds())]
        lastKeys = keys; lastClicks = clicks; micSec = 0
        return out
    }

    static func micLive() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr && running != 0
    }
}

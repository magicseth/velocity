import CryptoKit
import Foundation
import IOKit

/// ONE MAC, ONE ID. Velocity and Julia.app are two surfaces on the same machine; the
/// prefrontal component binds both to one `machineId` so a window seen by one and an act
/// sent through the other are the same machine's. Derived, never stored: sha-256 of the
/// hardware IOPlatformUUID, first 32 hex (prefrontal/1 `MachineId`).
///
/// THIS FILE IS BYTE-IDENTICAL IN BOTH REPOS (terminal-velocity and convexos/apps/mac) and
/// a verifier compares them — a drift here is a phantom second machine on the strip.
enum MachineIdentity {
    static let machineId: String = {
        let seed = platformUUID() ?? "host:" + ProcessInfo.processInfo.hostName
        return String(SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }()
    static let name: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    static let platform = "macos"

    /// The hardware UUID from the IORegistry (IOPlatformExpertDevice / kIOPlatformUUIDKey).
    static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0),
              let uuid = raw.takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return uuid
    }
}

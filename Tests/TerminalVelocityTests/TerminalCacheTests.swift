import XCTest
@testable import TerminalVelocity

final class TerminalCacheTests: XCTestCase {
    func testCacheRejectsReusedPIDReplacedProcessAndOldSnapshot() {
        let now = Date()
        let cached = CachedTerminal(id: "window", pid: 123, bundleID: "com.apple.Terminal", launch: now,
            appName: "Terminal", title: "review helper", windowTitle: "review helper", tabTitle: nil, documentPath: nil, saved: now)
        XCTAssertTrue(cached.isCurrent(bundleID: "com.apple.Terminal", launch: now))
        XCTAssertFalse(cached.isCurrent(bundleID: "com.apple.Terminal", launch: now.addingTimeInterval(1)))
        XCTAssertFalse(cached.isCurrent(bundleID: "other", launch: now))
        XCTAssertFalse(cached.isCurrent(bundleID: "com.apple.Terminal", launch: now, now: now.addingTimeInterval(86401)))
        var entry = WindowEntry(id: "cached", pid: 123, appName: "Terminal", title: "[!] Action Required", icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        entry.cachedTerminal = cached
        XCTAssertFalse(entry.canClose)
        XCTAssertEqual(entry.attention, .none)
    }
}

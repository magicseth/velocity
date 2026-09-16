import XCTest
@testable import TerminalVelocity

@MainActor final class LiveMatchingTests: XCTestCase {
    let windows = [MatchWindow(id: "0", app: "Terminal", title: "Waveshare")]
    func testAudioRefreshKeepsMatchesAndSelectionWhileTitleChangesInvalidateThem() {
        let model = PaletteModel()
        let entry = WindowEntry(id: "terminal", pid: 123, appName: "Terminal", title: "Waveshare", icon: nil,
                                element: nil, minimized: false, hidden: false, terminal: true)
        model.all = [entry]
        model.query = "touchscreen project"
        model.liveMatchIDs = [entry.id]
        model.filter()
        XCTAssertEqual(model.resultState.selectedID, entry.id)
        var updated = entry; updated.audio = .playing
        model.all = [updated]
        model.filter(preserveSelection: true)
        XCTAssertEqual(model.liveMatchIDs, [entry.id])
        XCTAssertEqual(model.resultState.selectedID, entry.id)
        updated.title = "Other project"
        model.all = [updated]
        XCTAssertTrue(model.liveMatchIDs.isEmpty)
    }
    func testDebounceCancellationAndCache() async throws {
        var calls: [String] = [], applied: [[String]] = []
        let matcher = LiveWindowMatcher(delay: 20_000_000) { query, _, _ in
            calls.append(query); return WindowMatches(ids: ["0"])
        }
        func schedule(_ query: String) {
            matcher.schedule(query: query, windows: windows, entryIDs: ["terminal"], endpoint: "test", status: { _ in }, apply: { applied.append($0) })
        }
        schedule("touch"); schedule("touchscreen")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(calls, ["touchscreen"])
        XCTAssertEqual(applied, [["terminal"]])
        matcher.cancel(); schedule("touchscreen")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(applied.count, 2)
        schedule("other"); matcher.cancel()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(calls.count, 1)
    }
    func testLateResponseCannotReplaceNewerQuery() async throws {
        var applied: [[String]] = []
        let matcher = LiveWindowMatcher(delay: 0) { query, _, _ in
            if query == "old" { try? await Task.sleep(nanoseconds: 80_000_000) }
            return WindowMatches(ids: query == "old" ? ["0"] : [])
        }
        matcher.schedule(query: "old", windows: windows, entryIDs: ["terminal"], endpoint: "test", status: { _ in }, apply: { applied.append($0) })
        try await Task.sleep(nanoseconds: 10_000_000)
        matcher.schedule(query: "new", windows: windows, entryIDs: ["terminal"], endpoint: "test", status: { _ in }, apply: { applied.append($0) })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(applied, [[]])
        XCTAssertThrowsError(try WindowMatches(ids: ["1"]).resolve(windows, entryIDs: ["terminal"]))
        XCTAssertThrowsError(try WindowMatches(ids: ["0", "0"]).resolve(windows, entryIDs: ["terminal"]))
    }
}

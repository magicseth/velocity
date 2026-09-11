import XCTest
@testable import TerminalVelocity

final class DefaultOrderingTests: XCTestCase {
    @MainActor func testOpeningClearsQueryAndPrioritizesAttentionButSearchStillMatches() {
        func entry(_ id: String, title: String, terminal: Bool) -> WindowEntry {
            WindowEntry(id: id, pid: 1, appName: terminal ? "Terminal" : "Notes", title: title, icon: nil,
                element: nil, minimized: false, hidden: false, terminal: terminal)
        }
        let notes = entry("notes", title: "Shopping list", terminal: false)
        let waiting = entry("waiting", title: "[ ! ] Action Required | Fix build — codex", terminal: true)
        let model = PaletteModel()
        var audio = entry("audio", title: "Music", terminal: false)
        audio.audio = .playing
        model.all = [notes, audio, waiting]
        model.query = "old query"
        model.openAllApps()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.results.map(\.id), ["waiting", "audio", "notes"])
        model.query = "Shopping"
        XCTAssertEqual(model.results.map(\.id), ["notes"])
    }
}

import XCTest
@testable import TerminalVelocity

final class SearchTests: XCTestCase {
    func testTokensCanMatchBothAppAndWindow() {
        XCTAssertNotNil(WindowSearch.score(query: "term server", title: "api server — zsh", app: "Terminal"))
        XCTAssertNil(WindowSearch.score(query: "term database", title: "api server — zsh", app: "Terminal"))
    }
    func testFuzzyAndUnicode() {
        XCTAssertNotNil(WindowSearch.score(query: "trm", title: "zsh", app: "Terminal"))
        XCTAssertNotNil(WindowSearch.score(query: "CAFE", title: "Café notes", app: "Notes"))
        XCTAssertNil(WindowSearch.score(query: "zyx", title: "xyz", app: "Notes"))
    }
    func testTitleMatchesRankAboveFuzzyMatches() {
        let exact = WindowSearch.score(query: "server", title: "server", app: "Terminal")!
        let contained = WindowSearch.score(query: "server", title: "api server", app: "Terminal")!
        XCTAssertGreaterThan(exact, contained)
        XCTAssertEqual(WindowSearch.score(query: "  \n", title: "anything", app: "anything"), 0)
    }

    func testLongQueriesDoNotMatchScatteredLettersInCommands() {
        XCTAssertNil(WindowSearch.score(query: "waveshare", title: "work and various events somehow have a really exciting ending", app: "Terminal"))
        XCTAssertNotNil(WindowSearch.score(query: "waveshare", title: "~/Projects/waveshare — zsh", app: "Terminal"))
    }

    func testLongTitleDisplaysTheMatchingPart() {
        let title = String(repeating: "long shell command ", count: 12) + "~/Projects/waveshare — zsh"
        let excerpt = WindowSearch.excerpt(query: "waveshare", title: title)
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertTrue(String(excerpt.prefix(70)).contains("waveshare"))
    }

    private func entry(app: String = "Visual Studio Code", path: String? = nil) -> WindowEntry {
        WindowEntry(id: "test", pid: 1, appName: app, title: "notes.txt", icon: nil,
                    element: nil, minimized: false, hidden: false, terminal: false, documentPath: path)
    }

    func testArbitraryAppNamesAndQuotedNames() {
        let query = SearchQuery("app:\"Visual Studio Code\" waveshare")
        XCTAssertEqual(query.text, "waveshare")
        XCTAssertTrue(query.accepts(entry(), recent: false))
        XCTAssertFalse(query.accepts(entry(app: "Notes"), recent: false))
        XCTAssertTrue(SearchQuery("@Obsidian").accepts(entry(app: "Obsidian"), recent: false))
        XCTAssertTrue(SearchQuery("@\"Visual Studio Code\"").accepts(entry(), recent: false))
        XCTAssertTrue(SearchQuery("app:Audio").accepts(entry(app: "Audio"), recent: false))
    }

    func testDocumentFoldersAndProjects() {
        let value = entry(path: "/Users/test/My Projects/waveshare/notes.txt")
        XCTAssertTrue(SearchQuery("folder:\"My Projects\"").accepts(value, recent: false))
        XCTAssertFalse(SearchQuery("folder:notes.txt").accepts(value, recent: false))
        XCTAssertFalse(SearchQuery("folder:waveshare").accepts(entry(), recent: false))
        XCTAssertNotNil(WindowSearch.score(query: "waveshare", title: value.searchText, app: value.appName))
        XCTAssertEqual(WindowCatalog.localDocumentPath("file:///Users/test/My%20Projects/notes.txt"), "/Users/test/My Projects/notes.txt")
        XCTAssertNil(WindowCatalog.localDocumentPath("https://example.com/notes.txt"))
    }

    func testRecentAndAppFiltersCombine() {
        let query = SearchQuery("@recent @Obsidian notes")
        XCTAssertEqual(query.text, "notes")
        XCTAssertFalse(query.accepts(entry(app: "Obsidian"), recent: false))
        XCTAssertTrue(query.accepts(entry(app: "Obsidian"), recent: true))
        XCTAssertFalse(query.accepts(entry(), recent: true))
    }

    func testRecentMemoryPersistsAndBoundsHistory() {
        let suite = "TerminalVelocityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = SelectionMemory(defaults: defaults)
        for index in 0..<90 { memory.record("key-\(index)", at: Date(timeIntervalSince1970: Double(index + 1))) }
        let restored = SelectionMemory(defaults: defaults)
        XCTAssertEqual(restored.recent.count, 80)
        XCTAssertNil(restored.recent["key-0"])
        XCTAssertEqual(restored.recent["key-89"], 90)
    }

    @MainActor func testRecentSwitchingPrefersPreviousAndKeepsSearchRelevance() {
        let suite = "TerminalVelocityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = SelectionMemory(defaults: defaults)
        let first = entry(app: "First"), second = entry(app: "Second"), untouched = entry(app: "Untouched")
        memory.observe(first.memoryKey, at: Date(timeIntervalSince1970: 100))
        memory.observe(first.memoryKey, at: Date(timeIntervalSince1970: 110))
        XCTAssertEqual(memory.recent[first.memoryKey], 100, "Polling the same destination must not reorder history")
        memory.observe(second.memoryKey, at: Date(timeIntervalSince1970: 120))
        let model = PaletteModel(memory: memory)
        model.all = [untouched, second, first]
        model.filter()
        XCTAssertEqual(model.results.map(\.appName), ["First", "Second", "Untouched"])
        model.query = "Second"
        XCTAssertEqual(model.results.map(\.appName), ["Second"])
        model.query = "@recent"
        XCTAssertEqual(model.results.map(\.appName), ["First", "Second"])
    }
}

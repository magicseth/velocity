import XCTest
import ApplicationServices
@testable import TerminalVelocity

final class JuliaLinkTests: XCTestCase {
    func waiting(_ id: String = "one", task: String = "Integrate HIVE-style dependency", pid: pid_t = 801) -> WindowEntry {
        WindowEntry(id: id, pid: pid, appName: "Terminal",
            title: "~/Projects/convexos — [ ! ] Action Required | \(task) | convexos — codex",
            icon: nil, element: AXUIElementCreateApplication(pid), minimized: false, hidden: false, terminal: true)
    }
    @MainActor func testAWaitingTerminalBecomesOneBoardRowWithAJumpHandleBack() throws {
        let launch = Date(timeIntervalSince1970: 100)
        let entry = waiting()
        let idle = WindowEntry(id: "two", pid: 802, appName: "Terminal", title: "~/Projects/ds4 — zsh", icon: nil,
            element: AXUIElementCreateApplication(802), minimized: false, hidden: false, terminal: true)
        let reports = JuliaReporter.reports([entry, idle]) { $0 == 801 ? launch : nil }
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.project, "convexos")
        XCTAssertEqual(report.subtask, "Integrate HIVE-style dependency")
        XCTAssertEqual(report.externalId.count, 32)
        let destination = try XCTUnwrap(JuliaJumpHandle.decode(try XCTUnwrap(report.jumpHandle)))
        XCTAssertEqual(destination.resolve([entry], launch: launch)?.id, entry.id)
        XCTAssertNil(destination.resolve([entry], launch: launch.addingTimeInterval(1)), "a replaced process is never focused by title")
        XCTAssertNil(JuliaJumpHandle.decode("not a handle"))
        XCTAssertNil(JuliaReporter.reports([entry]) { _ in nil }.first?.jumpHandle, "no launch date, no handle — never a guess")
    }
    func testTerminalChromeNeverBecomesTheProject() {
        // Terminal.app on this Mac prefixes "magicseth — " and appends " — sleep 600".
        let chrome = WindowEntry(id: "one", pid: 801, appName: "Terminal",
            title: "magicseth — ~/Projects/convexos — [ ! ] Action Required | Prove the Velocity loop | convexos — codex — sleep 600",
            icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        XCTAssertEqual(AttentionPresentation(chrome).project, "convexos")
        XCTAssertEqual(AttentionPresentation(chrome).task, "Prove the Velocity loop")
        let bare = WindowEntry(id: "two", pid: 801, appName: "Terminal",
            title: "~/Projects/ds4 — [ ! ] Action Required | Pick a port — claude",
            icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        XCTAssertEqual(AttentionPresentation(bare).project, "ds4", "no tail: the folder prefix still works")
        XCTAssertEqual(AttentionPresentation(bare).task, "Pick a port")
    }
    func testTheBoardIsOnlyToldAboutChangesAndResolvesAfterTheLatch() {
        var reporter = JuliaReporter(latch: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = JuliaReport(externalId: "a", project: "convexos", subtask: "Fix CI", jumpHandle: nil)
        let b = JuliaReport(externalId: "b", project: "ds4", subtask: "Pick a port", jumpHandle: nil)
        XCTAssertEqual(reporter.observe([a, b], now: t0), JuliaReportDiff(report: [a, b], resolve: []))
        XCTAssertEqual(reporter.observe([a, b], now: t0.addingTimeInterval(1)), JuliaReportDiff(), "same scan, no chatter")
        XCTAssertEqual(reporter.observe([a], now: t0.addingTimeInterval(2)), JuliaReportDiff(), "a blink is not a resolution")
        XCTAssertEqual(reporter.observe([a, b], now: t0.addingTimeInterval(3)), JuliaReportDiff(), "it came back: still nothing to say")
        XCTAssertEqual(reporter.observe([a], now: t0.addingTimeInterval(4)), JuliaReportDiff())
        XCTAssertEqual(reporter.observe([a], now: t0.addingTimeInterval(15)), JuliaReportDiff(report: [], resolve: ["b"]))
        let a2 = JuliaReport(externalId: "a", project: "convexos", subtask: "Fix CI (rust)", jumpHandle: nil)
        XCTAssertEqual(reporter.observe([a2], now: t0.addingTimeInterval(16)), JuliaReportDiff(report: [a2], resolve: []), "a changed subtask is re-reported")
        XCTAssertEqual(reporter.current.count, 1)
    }
    func testARestartStillResolvesWhatItReportedBefore() {
        var reporter = JuliaReporter(latch: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        reporter.restore([JuliaReport(externalId: "old", project: "x", subtask: "y", jumpHandle: nil)], now: t0)
        XCTAssertEqual(reporter.observe([], now: t0).resolve, ["old"])
    }
    @MainActor func testTheContractNamesAndTheLinkShape() throws {
        XCTAssertEqual(JuliaClient.Function.report.rawValue, "attention:report")
        XCTAssertEqual(JuliaClient.Function.resolve.rawValue, "attention:resolve")
        XCTAssertEqual(JuliaClient.Function.createCode.rawValue, "pairing:createCode")
        XCTAssertEqual(JuliaClient.Function.status.rawValue, "pairing:status")
        XCTAssertEqual(JuliaClient.Function.status.kind, "query")
        XCTAssertEqual(JuliaClient.Function.report.kind, "mutation")
        XCTAssertEqual(try JuliaClient(endpoint: "https://hidden-kudu-77.convex.cloud").endpoint.host, "hidden-kudu-77.convex.cloud")
        XCTAssertThrowsError(try JuliaClient(endpoint: "http://hidden-kudu-77.convex.cloud"))
        XCTAssertThrowsError(try JuliaClient(endpoint: "https://evil.example.com"))
        XCTAssertEqual(JuliaLink.handle(in: URL(string: "velocity://focus?handle=abc_-1")!), "abc_-1")
        XCTAssertNil(JuliaLink.handle(in: URL(string: "velocity://other?handle=abc")!))
        XCTAssertNil(JuliaLink.handle(in: URL(string: "velocity://focus")!))
    }
}

final class JuliaWorkspaceTests: XCTestCase {
    func entry(_ id: String, app: String, title: String, terminal: Bool = false, path: String? = nil, url: String? = nil) -> WindowEntry {
        var e = WindowEntry(id: id, pid: 900, appName: app, title: title, icon: nil, element: nil,
            minimized: false, hidden: false, terminal: terminal)
        e.documentPath = path
        if let url {
            e.browserTab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: 1, title: title, url: url,
                minimized: false, windowTitle: title, index: 0)
            e.browser = true
        }
        return e
    }
    func testWindowsAreMatchedToAProjectByWhatTheySayAboutThemselves() {
        let entries = [
            entry("t1", app: "Terminal", title: "~/Projects/convexos — zsh", terminal: true),
            entry("b1", app: "Google Chrome", title: "Pull requests · magicseth/convexos", url: "https://github.com/magicseth/convexos/pulls"),
            entry("d1", app: "Xcode", title: "AppModel.swift", path: "/Users/seth/Projects/convexos/apps/mac/AppModel.swift"),
            entry("x1", app: "Finder", title: "Downloads"),
            entry("t2", app: "Terminal", title: "~/Projects/ds4 — zsh", terminal: true),
        ]
        let windows = JuliaWorkspace.windows(for: "convexos", in: entries)
        XCTAssertEqual(windows.map(\.key), ["t1", "d1", "b1"], "terminals lead, then documents, then tabs")
        XCTAssertEqual(windows.map(\.kind), ["terminal", "document", "browser"])
        let busy = entry("t9", app: "Terminal", title: "◐ Fixing the strip — claude", terminal: true)
        XCTAssertEqual(JuliaWorkspace.state(busy), "working", "a spinner title is an agent at work")
        XCTAssertNil(JuliaWorkspace.state(entries[0]), "a plain shell has no agent state")
        XCTAssertEqual(JuliaWorkspace.windows(for: "Convex OS", in: entries).map(\.key), ["t1", "d1", "b1"], "squash: spacing and case never matter")
        XCTAssertTrue(JuliaWorkspace.windows(for: "ds", in: entries).isEmpty, "a two-letter name matches nothing")
        let group = JuliaWorkspace.group(for: "ds4", in: entries)
        XCTAssertEqual(group?.lead.id, "t2")
        let manifest = JuliaWorkspace.manifest(projects: ["convexos"], entries: entries)
        XCTAssertEqual(manifest["*"]?.map(\.key), ["t2"], "the ds4 terminal matched no project by name: it goes to the * bucket for Jev; the Finder window stays local")
    }
    func testOnlyChangesReachTheBoardAndAnEmptiedProjectIsForgotten() {
        let a = [JuliaWindow(key: "t1", kind: "terminal", app: "Terminal", title: "x")]
        let previous = ["convexos": a, "ds4": a]
        let current = ["convexos": a, "waveshare": a]
        let changes = JuliaWorkspace.changes(previous: previous, current: current)
        XCTAssertEqual(changes["waveshare"], a)
        XCTAssertEqual(changes["ds4"], [], "went away: the board forgets it")
        XCTAssertNil(changes["convexos"], "unchanged: silence")
    }
    func testANewTerminalOpensInHisTerminalAndOnlyInARealFolderUnderHome() {
        let t = WindowEntry(id: "t", pid: 5, appName: "Ghostty", title: "x", icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        let u = WindowEntry(id: "u", pid: 6, appName: "Terminal", title: "y", icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        let running: [(pid: pid_t, bundle: String)] = [(5, "com.mitchellh.ghostty"), (6, "com.apple.Terminal")]
        XCTAssertEqual(JuliaWorkspace.preferredTerminal([t, t, u], running: running), "com.mitchellh.ghostty")
        XCTAssertEqual(JuliaWorkspace.preferredTerminal([], running: running), "com.apple.Terminal")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertNotNil(JuliaWorkspace.terminalDirectory(home + "/Library"))
        XCTAssertNil(JuliaWorkspace.terminalDirectory("/etc"), "outside home: never")
        XCTAssertNil(JuliaWorkspace.terminalDirectory(home + "/definitely-not-here-\(UUID().uuidString)"))
        XCTAssertNil(JuliaWorkspace.terminalDirectory(nil))
    }
    func testATitleThatReadsLikeASecretNeverLeavesTheMac() {
        XCTAssertTrue(JuliaWorkspace.looksSensitive("Your login code is 286525 - seth@example.com - Mail"))
        XCTAssertTrue(JuliaWorkspace.looksSensitive("Reset your password · GitHub"))
        XCTAssertTrue(JuliaWorkspace.looksSensitive("483920 is your verification code"))
        XCTAssertFalse(JuliaWorkspace.looksSensitive("Pull requests · magicseth/convexos"))
        XCTAssertFalse(JuliaWorkspace.looksSensitive("~/Projects/convexos — zsh"))
        let mail = entry("m1", app: "Google Chrome", title: "Your login code is 286525 - convexos - Mail", url: "https://mail.example.com/x")
        XCTAssertTrue(JuliaWorkspace.windows(for: "convexos", in: [mail]).isEmpty, "even a name match does not ship a code")
        XCTAssertTrue(JuliaWorkspace.manifest(projects: ["convexos"], entries: [mail])["*"]?.isEmpty ?? false)
    }
    func testTheURLShapes() {
        XCTAssertEqual(JuliaWorkspace.query(in: URL(string: "velocity://foreground?project=convex%20os")!, "project"), "convex os")
        XCTAssertEqual(JuliaWorkspace.query(in: URL(string: "velocity://focus?project=x&window=901%3Awindow%3A5")!, "window"), "901:window:5")
    }
}

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

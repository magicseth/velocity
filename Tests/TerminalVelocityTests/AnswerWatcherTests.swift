import XCTest
@testable import TerminalVelocity

final class AnswerWatcherTests: XCTestCase {
    func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
    func user(_ text: String, _ ts: String, uuid: String = "u1") -> String {
        line(["type": "user", "uuid": uuid, "timestamp": ts, "cwd": "/Users/x/Projects/demo", "sessionId": "S", "message": ["role": "user", "content": text]])
    }
    func assistant(_ text: String?, _ ts: String, stop: String, tool: Bool = false) -> String {
        var parts: [[String: Any]] = []
        if let text { parts.append(["type": "text", "text": text]) }
        if tool { parts.append(["type": "tool_use", "name": "Bash", "input": ["command": "echo sk-abc123DEF456ghi789jkl"]]) }
        return line(["type": "assistant", "timestamp": ts, "cwd": "/Users/x/Projects/demo", "sessionId": "S", "message": ["role": "assistant", "stop_reason": stop, "content": parts]])
    }
    func testAClaudeTurnIsWorkingUntilEndTurnThenAnswered() {
        var lines = [user("does convex-test support crons?", "2026-09-21T10:00:00.000Z"), assistant("Let me check.", "2026-09-21T10:00:05.000Z", stop: "tool_use", tool: true)]
        var e = AnswerWatcher.claude(lines, path: "/x/S.jsonl")
        XCTAssertEqual(e?.question, "does convex-test support crons?")
        XCTAssertEqual(e?.done, false, "a tool call is not an answer")
        lines.append(assistant("Yes — via t.finishAllScheduledFunctions.", "2026-09-21T10:01:00.000Z", stop: "end_turn"))
        e = AnswerWatcher.claude(lines, path: "/x/S.jsonl")
        XCTAssertEqual(e?.done, true)
        XCTAssertEqual(e?.answer, "Yes — via t.finishAllScheduledFunctions.")
        XCTAssertEqual(e?.cwd, "/Users/x/Projects/demo")
        XCTAssertEqual(e?.externalId, "claude-cli:S:u1", "one row per QUESTION")
        // He carries on: the new question replaces the old exchange (Julia supersedes it).
        lines.append(user("and actions?", "2026-09-21T10:02:00.000Z", uuid: "u2"))
        e = AnswerWatcher.claude(lines, path: "/x/S.jsonl")
        XCTAssertEqual(e?.externalId, "claude-cli:S:u2"); XCTAssertEqual(e?.done, false); XCTAssertNil(e?.answer)
    }
    func testAPasteIsHisTurnButItsBodyNeverLeaves() {
        let lines = [user("paste me the token", "2026-09-21T10:00:00.000Z"),
                     assistant("Please paste the token here.", "2026-09-21T10:00:05.000Z", stop: "end_turn"),
                     user("\n\n<pasted_content id=\"925c\">\nToken created successfully\nquiet-water-9859\nabcDEF123456\n</pasted_content>", "2026-09-21T10:01:00.000Z", uuid: "u2")]
        let e = AnswerWatcher.claude(lines, path: "/x/S.jsonl")
        XCTAssertEqual(e?.externalId, "claude-cli:S:u2", "the paste is a new turn of his: the old answer no longer needs him")
        XCTAssertEqual(e?.question, "(pasted text)")
        XCTAssertNil(e?.answer)
        XCTAssertFalse(e?.question.contains("quiet-water") ?? true, "the pasted body never leaves")
    }
    func testOnlyHisWordsAndTheAgentsProseEverLeave() {
        let toolResult = line(["type": "user", "timestamp": "2026-09-21T10:00:01.000Z", "message": ["role": "user", "content": [["type": "tool_result", "content": "secret output"]]]])
        let reminder = user("<system-reminder>do things</system-reminder>", "2026-09-21T10:00:02.000Z", uuid: "u9")
        let sidechain = line(["type": "user", "isSidechain": true, "uuid": "sc", "timestamp": "2026-09-21T10:00:03.000Z", "message": ["role": "user", "content": "sub-agent prompt"]])
        XCTAssertNil(AnswerWatcher.claude([toolResult, reminder, sidechain], path: "/x/S.jsonl"), "tool results, injected reminders and sub-agent prompts are not questions he asked")
        let leaky = [user("deploy it", "2026-09-21T10:00:00.000Z"), assistant("Done.\nexport api key = 12345\nIt is live.", "2026-09-21T10:00:09.000Z", stop: "end_turn")]
        XCTAssertEqual(AnswerWatcher.claude(leaky, path: "/x/S.jsonl")?.answer, "Done.\nIt is live.", "a secret-shaped line is refused; the rest stands")
    }
    func testHisQuestionIsFoundEvenMegabytesBackAndTheOffsetIsRemembered() throws {
        // Measured on a real session: his last question sat 1.13 MB from the end; a fixed 384 KB tail found nothing.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl").path
        let noise = (0..<40).map { i in line(["type": "user", "timestamp": "2026-09-21T10:00:0\(i % 10).000Z", "message": ["role": "user", "content": [["type": "tool_result", "content": String(repeating: "x", count: 60_000)]]]]) }
        let rows = [user("old question", "2026-09-21T09:00:00.000Z", uuid: "old"), assistant("old answer", "2026-09-21T09:01:00.000Z", stop: "end_turn"),
                    user("is the strip fixed?", "2026-09-21T10:00:00.000Z", uuid: "q2")] + noise + [assistant("Yes — verified by the stress test.", "2026-09-21T10:30:00.000Z", stop: "end_turn")]
        try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let (e, offset) = try XCTUnwrap(AnswerWatcher.read(path, from: nil))
        XCTAssertEqual(e.question, "is the strip fixed?"); XCTAssertTrue(e.done); XCTAssertEqual(e.answer, "Yes — verified by the stress test.")
        XCTAssertGreaterThan(offset, 0)
        let again = try XCTUnwrap(AnswerWatcher.read(path, from: offset))
        XCTAssertEqual(again.0, e, "reading from the remembered offset gives the same exchange, without re-reading the file")
        XCTAssertEqual(again.1, offset)
    }
    func testAScreenshotIsAnAttachmentNotHisWords() {
        let both = [user("[Image #10] i clicked open it but it didn't work [Image: source: /Users/x/.claude/image-cache/10.png]", "2026-09-21T10:00:00.000Z"), assistant("On it.", "2026-09-21T10:00:05.000Z", stop: "end_turn")]
        XCTAssertEqual(AnswerWatcher.claude(both, path: "/x/S.jsonl")?.question, "i clicked open it but it didn't work", "no placeholder, no local path")
        let only = [user("[Image #9] [Image: source: /Users/x/.claude/image-cache/9.png]", "2026-09-21T10:00:00.000Z"), assistant("Seen.", "2026-09-21T10:00:05.000Z", stop: "end_turn")]
        XCTAssertEqual(AnswerWatcher.claude(only, path: "/x/S.jsonl")?.question, "(a screenshot, no words)")
    }
    func testAProgrammaticClaudeRunIsNotAQuestionHeAsked() {
        let sdk = line(["type": "user", "uuid": "p1", "entrypoint": "sdk-cli", "timestamp": "2026-09-21T10:00:00.000Z", "message": ["role": "user", "content": "You are an expert software architect providing a codebase walkthrough"]])
        let done = line(["type": "assistant", "entrypoint": "sdk-cli", "timestamp": "2026-09-21T10:01:00.000Z", "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Here is the walkthrough."]]]])
        XCTAssertNil(AnswerWatcher.claude([sdk, done], path: "/x/S.jsonl"), "reviewHelper-style SDK runs never reach his inbox")
    }
    func testCodexAnswersOnTaskCompleteAndNeverReportsExecRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/.codex/sessions"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ source: String) throws -> String {
            let path = dir.appendingPathComponent("rollout-\(source).jsonl").path
            let rows: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": "C1", "cwd": "/Users/x/Projects/demo", "source": source]],
                ["type": "event_msg", "timestamp": "2026-09-21T10:00:00.000Z", "payload": ["type": "task_started"]],
                ["type": "response_item", "timestamp": "2026-09-21T10:00:00.000Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "fix the failing test"]]]],
                ["type": "response_item", "timestamp": "2026-09-21T10:03:00.000Z", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Fixed: the mock clock was off by one."]]]],
                ["type": "event_msg", "timestamp": "2026-09-21T10:03:01.000Z", "payload": ["type": "task_complete"]],
            ]
            try rows.map(line).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        let mine = try XCTUnwrap(AnswerWatcher.parse(try write("cli")))
        XCTAssertEqual(mine.done, true); XCTAssertEqual(mine.answer, "Fixed: the mock clock was off by one."); XCTAssertEqual(mine.source, "Codex")
        XCTAssertNil(AnswerWatcher.parse(try write("exec")), "a program ran that one; he did not ask")
    }
}

@MainActor final class ChromeEnrichTests: XCTestCase {
    func testTheFastListKeepsItsTabsAndTakesTheScansEnrichment() {
        let fast = [WindowEntry(id: "1:browser:2:3", pid: 1, appName: "Google Chrome", title: "Video", icon: nil, element: nil, minimized: false, hidden: false, terminal: false, browser: true),
                    WindowEntry(id: "1:browser:2:4", pid: 1, appName: "Google Chrome", title: "New", icon: nil, element: nil, minimized: false, hidden: false, terminal: false, browser: true)]
        var scanned = WindowEntry(id: "1:browser:2:3", pid: 1, appName: "Google Chrome", title: "Video", icon: nil, element: nil, minimized: false, hidden: false, terminal: false, browser: true)
        scanned.audio = .playing; scanned.browserProfile = "Seth"
        let stale = WindowEntry(id: "1:browser:2:9", pid: 1, appName: "Google Chrome", title: "Closed", icon: nil, element: nil, minimized: false, hidden: false, terminal: false, browser: true)
        let merged = AppDelegate.enrich(fast, from: [scanned, stale])
        XCTAssertEqual(merged.map(\.id), ["1:browser:2:3", "1:browser:2:4"], "the newer list's tabs, and only those")
        XCTAssertEqual(merged[0].audio, .playing, "the scan's audio badge lands on the fast entry")
        XCTAssertEqual(merged[0].browserProfile, "Seth")
        XCTAssertEqual(merged[1].audio, .none)
    }
}

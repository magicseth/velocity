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
    func testOnlyHisWordsAndTheAgentsProseEverLeave() {
        let toolResult = line(["type": "user", "timestamp": "2026-09-21T10:00:01.000Z", "message": ["role": "user", "content": [["type": "tool_result", "content": "secret output"]]]])
        let reminder = user("<system-reminder>do things</system-reminder>", "2026-09-21T10:00:02.000Z", uuid: "u9")
        let sidechain = line(["type": "user", "isSidechain": true, "uuid": "sc", "timestamp": "2026-09-21T10:00:03.000Z", "message": ["role": "user", "content": "sub-agent prompt"]])
        XCTAssertNil(AnswerWatcher.claude([toolResult, reminder, sidechain], path: "/x/S.jsonl"), "tool results, injected reminders and sub-agent prompts are not questions he asked")
        let leaky = [user("deploy it", "2026-09-21T10:00:00.000Z"), assistant("Done.\nexport api key = 12345\nIt is live.", "2026-09-21T10:00:09.000Z", stop: "end_turn")]
        XCTAssertEqual(AnswerWatcher.claude(leaky, path: "/x/S.jsonl")?.answer, "Done.\nIt is live.", "a secret-shaped line is refused; the rest stands")
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

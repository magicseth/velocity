import XCTest
import ApplicationServices
@testable import TerminalVelocity

/// "Yes" is bound to the exact prompt he saw; Codex has a state; each dialog is its own ask.
final class ApproveBindingTests: XCTestCase {
    static let codexDialog = """
    Would you like to run the following command?
    $ rm -rf build
    › 1. Yes, proceed (y)
    2. No, and tell Codex what to do differently (esc)
    Press enter to confirm or esc to cancel
    """

    // MARK: 1. the digest (the server implements the identical function in TS)

    func testTheDigestFixturesTheServerMustMatch() {
        XCTAssertEqual(AttentionPrompt.normalized("  A \n\n B  "), "A\nB")
        XCTAssertEqual(AttentionPrompt.digest("  A \n\n B  "), "23519a43c66b4c342f25b32e09797ec5f3fc0be388cd8243fb3449afbdce4013")
        XCTAssertEqual(AttentionPrompt.digest("A\nB"), AttentionPrompt.digest("\n  A\r\n\tB\n\n"), "CR, tabs and blank lines never change the identity")
        XCTAssertEqual(AttentionPrompt.digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(AttentionPrompt.digest(Self.codexDialog), "db077ed5575ee48f6842facbca61124bc576ebe58ca2286218734c940c61b3f4")
        XCTAssertNotEqual(AttentionPrompt.digest("A\nB"), AttentionPrompt.digest("B\nA"))
    }

    func testApproveProceedsOnlyWhenTheScreenIsTheQuestionHeSaw() throws {
        let screen = "some earlier output\n" + Self.codexDialog + "\n"
        let shown = try XCTUnwrap(AttentionPrompt.extract(screen))
        let digest = AttentionPrompt.digest(shown)
        XCTAssertEqual(ApproveGate.before(screen: screen, digest: digest, lastReported: nil), .proceed(digest: digest, prompt: shown))
        XCTAssertEqual(ApproveGate.before(screen: screen, digest: digest.uppercased(), lastReported: nil), .proceed(digest: digest, prompt: shown))
        // A different dialog took its place: refuse, never press.
        let other = screen.replacingOccurrences(of: "rm -rf build", with: "git push --force")
        guard case .refuse(let receipt) = ApproveGate.before(screen: other, digest: digest, lastReported: nil) else { return XCTFail("a changed question must be refused") }
        XCTAssertEqual(receipt, .failed(class: "changed", why: "The question on screen changed — open it to decide."))
        // Nothing asked any more.
        guard case .refuse(let stale) = ApproveGate.before(screen: "✔ done\n› ", digest: digest, lastReported: nil) else { return XCTFail() }
        if case .failed(let cls, _) = stale { XCTAssertEqual(cls, "stale") } else { XCTFail() }
        XCTAssertNotEqual(ApproveGate.before(screen: nil, digest: digest, lastReported: nil), .proceed(digest: digest, prompt: shown))
    }

    func testAnOlderJuliaWithNoDigestIsNeverBlind() throws {
        let screen = Self.codexDialog
        let shown = try XCTUnwrap(AttentionPrompt.extract(screen))
        XCTAssertEqual(ApproveGate.before(screen: screen, digest: nil, lastReported: shown), .proceed(digest: AttentionPrompt.digest(shown), prompt: shown), "the prompt this Mac reported may be answered")
        XCTAssertEqual(ApproveGate.before(screen: screen, digest: "", lastReported: shown), .proceed(digest: AttentionPrompt.digest(shown), prompt: shown))
        if case .proceed = ApproveGate.before(screen: screen, digest: nil, lastReported: nil) { XCTFail("no digest and no report: refuse") }
        if case .proceed = ApproveGate.before(screen: screen, digest: nil, lastReported: "Do you want to proceed?\n❯ 1. Yes") { XCTFail("a different reported prompt: refuse") }
    }

    func testAfterOnePressTheOutcomeIsSaidHonestlyAndNeverAnswered() throws {
        let shown = try XCTUnwrap(AttentionPrompt.extract(Self.codexDialog))
        let digest = AttentionPrompt.digest(shown)
        XCTAssertEqual(ApproveGate.after(screen: Self.codexDialog, approved: shown), .stillAsking)
        XCTAssertEqual(ApproveGate.after(screen: "✔ You approved codex to run rm -rf build\n• Working (2s • esc to interrupt)", approved: shown), .cleared)
        XCTAssertEqual(ApproveGate.after(screen: Self.codexDialog + "\nGOT RETURN\n", approved: shown), .cleared, "the answered dialog left in the scrollback with output under it is answered, not new")
        let next = "Would you like to make the following edits?\nsrc/a.ts (+2 -1)\n› 1. Yes, proceed (y)\nPress enter to confirm or esc to cancel"
        guard case .newAsk(let d2) = ApproveGate.after(screen: next, approved: shown) else { return XCTFail("a different dialog is a new ask") }
        XCTAssertNotEqual(d2, digest)
        XCTAssertNil(ApproveGate.after(screen: nil, approved: shown))
        guard case .newAsk = ApproveGate.after(screen: Self.codexDialog + "\n" + next, approved: shown) else { return XCTFail("a new dialog under the answered one is a new ask") }
        // Receipts name the digest; a lingering dialog is uncertain, never "verified".
        if case .verified(_, let observed) = ApproveGate.receipt(.cleared, digest: digest, tty: "ttys001", keys: "Return") { XCTAssertTrue(observed.contains(digest)) } else { XCTFail() }
        if case .verified(_, let observed) = ApproveGate.receipt(.newAsk(digest: d2), digest: digest, tty: "ttys001", keys: "Return") {
            XCTAssertTrue(observed.contains(digest)); XCTAssertTrue(observed.contains("not answered"))
        } else { XCTFail() }
        if case .failed(let cls, let why) = ApproveGate.receipt(.stillAsking, digest: digest, tty: "ttys001", keys: "Return") {
            XCTAssertEqual(cls, "uncertain"); XCTAssertTrue(why.contains(digest)); XCTAssertTrue(why.contains("once"))
        } else { XCTFail() }
        if case .failed(let cls, _) = ApproveGate.receipt(nil, digest: digest, tty: "ttys001", keys: "Return") { XCTAssertEqual(cls, "uncertain") } else { XCTFail() }
    }

    func testTheApproveCommandCarriesTheDigest() throws {
        let json = #"{"id":"c1","machineId":"m","kind":"approve","status":"queued","args":{"handle":"h","harness":"codex","digest":"abc123"}}"#
        let command = try JSONDecoder().decode(PrefrontalCommand.self, from: Data(json.utf8))
        let url = try XCTUnwrap(command.velocityURL)
        XCTAssertEqual(JuliaWorkspace.query(in: url, "digest"), "abc123")
        XCTAssertEqual(url.host, "approve")
    }

    // MARK: 2. Codex working / idle / needs input

    func testCodexHasAStateLikeClaude() {
        let working = "amusebot — ⠸ Build WS0 spine | amusebot — codex ◂ node ~/.nvm/versions/node/v22.22.2/bin/codex — 135×41"
        let idle = "authv2 — Harden Auth v2 key handling | authv2 — codex ◂ node ~/.nvm/versions/node/v22.22.2/bin/codex — 120×30"
        let asking = "e2e — [ ! ] Action Required | E2E test — codex ◂ node ~/.nvm/versions/node/v22.22.2/bin/codex — 120×30"
        let claudeTaskInCodex = "domaincomponent — Review Claude transcript | domaincomponent — codex ◂ node /bin/codex — 120×30"
        XCTAssertEqual(AgentAttention.detect(title: working, terminal: true), .working)
        XCTAssertEqual(AgentAttention.detect(title: idle, terminal: true), .idle)
        XCTAssertEqual(AgentAttention.detect(title: asking, terminal: true), .needsInput)
        XCTAssertEqual(AgentAttention.detect(title: claudeTaskInCodex, terminal: true), .idle, "the process chain says Codex, whatever the task says")
        XCTAssertEqual(AgentAttention.detect(title: "⠙ Build WS0 spine | amusebot", terminal: true), .working, "a bare tab title: the spinner is Codex's")
        // Claude is untouched; a folder named codex is not an agent.
        XCTAssertEqual(AgentAttention.detect(title: "convexos — ◐ Convex OS — caffeinate ◂ claude --resume — 111×53", terminal: true), .working)
        XCTAssertEqual(AgentAttention.detect(title: "makeabook — ✳ Book tool — sourcekit-lsp ◂ claude --resume — 120×30", terminal: true), .idle)
        XCTAssertEqual(AgentAttention.detect(title: "~/Projects/codex — -zsh — 120×30", terminal: true), .none)
        XCTAssertEqual(AgentAttention.detect(title: working, terminal: false), .none)
        let entry = WindowEntry(id: "w", pid: 1, appName: "Terminal", title: working, icon: nil, element: nil, minimized: false, hidden: false, terminal: true)
        XCTAssertEqual(JuliaWorkspace.state(entry), "working")
    }

    func testTheScreenDecidesWhetherAnActionRequiredCodexIsAsking() {
        XCTAssertEqual(AttentionPrompt.screenState(Self.codexDialog), "needs_input")
        XCTAssertEqual(AttentionPrompt.screenState("› Explain this codebase\n\n• Working (12s • esc to interrupt)\n"), "working")
        XCTAssertEqual(AttentionPrompt.screenState("• Done. All 42 tests pass.\n\n› Ask Codex to do anything\n  ? for shortcuts"), "idle")
        XCTAssertNil(AttentionPrompt.screenState(nil))
        XCTAssertNil(AttentionPrompt.screenState("  \n"))
        let w = JuliaWindow(key: "k", kind: "terminal", app: "Terminal", title: "[ ! ] Action Required | x", state: "needs_input", task: nil, sig: nil)
        let unread = JuliaWindow(key: "u", kind: "terminal", app: "Terminal", title: "[ ! ] Action Required | y", state: "needs_input", task: nil, sig: nil)
        let refined = JuliaLink.refine(["p": [w, unread]], screens: ["k": "• Done.\n› Ask Codex to do anything"])
        XCTAssertEqual(refined["p"]?.map(\.state), ["idle", "needs_input"], "a finished turn is idle; an unread screen keeps the title's word")
    }

    // MARK: 3. per-prompt identity + re-assert

    func testEachDialogInATabIsItsOwnAsk() {
        let a = JuliaReporter.externalId(key: "tab", prompt: Self.codexDialog)
        let b = JuliaReporter.externalId(key: "tab", prompt: Self.codexDialog.replacingOccurrences(of: "rm -rf build", with: "ls"))
        XCTAssertNotEqual(a, b, "a new dialog in the same tab is a new ask")
        XCTAssertEqual(a, JuliaReporter.externalId(key: "tab", prompt: "  " + Self.codexDialog + "\n\n"), "the same question, re-read, is the same ask")
        XCTAssertEqual(JuliaReporter.externalId(key: "tab", prompt: nil), JuliaJumpHandle.id("tab"))
        XCTAssertEqual(a.count, 32)
    }

    @MainActor func testTheReportCarriesThePromptsIdentity() throws {
        let entry = WindowEntry(id: "one", pid: 801, appName: "Terminal",
            title: "~/Projects/convexos — [ ! ] Action Required | E2E test | convexos — codex",
            icon: nil, element: AXUIElementCreateApplication(801), minimized: false, hidden: false, terminal: true)
        let first = try XCTUnwrap(JuliaReporter.reports([entry], launch: { _ in Date(timeIntervalSince1970: 1) }) { _ in (tty: "ttys009", contents: Self.codexDialog) }.first)
        let second = try XCTUnwrap(JuliaReporter.reports([entry], launch: { _ in Date(timeIntervalSince1970: 1) }) { _ in (tty: "ttys009", contents: Self.codexDialog.replacingOccurrences(of: "rm -rf build", with: "make")) }.first)
        XCTAssertNotNil(first.prompt)
        XCTAssertNotEqual(first.externalId, second.externalId)
    }

    func testALiveReportIsReassertedEveryMinute() {
        var reporter = JuliaReporter(latch: 10, reassert: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = JuliaReport(externalId: "a", project: "p", subtask: "s", jumpHandle: nil)
        XCTAssertEqual(reporter.observe([a], now: t0).report, [a])
        XCTAssertEqual(reporter.observe([a], now: t0.addingTimeInterval(30)).report, [], "unchanged and recent: quiet")
        XCTAssertEqual(reporter.observe([a], now: t0.addingTimeInterval(61)).report, [a], "the server may have closed it: say it again")
        XCTAssertEqual(reporter.observe([a], now: t0.addingTimeInterval(90)).report, [])
        XCTAssertEqual(reporter.observe([], now: t0.addingTimeInterval(200)).resolve, ["a"])
        XCTAssertEqual(reporter.observe([], now: t0.addingTimeInterval(300)), JuliaReportDiff(), "a resolved report is not re-asserted")
        // After a restart what is still waiting is re-asserted at once.
        var restarted = JuliaReporter(latch: 10, reassert: 60)
        restarted.restore([a], now: t0)
        XCTAssertEqual(restarted.observe([a], now: t0).report, [a])
    }

    func testTheBackendIsASettingDefaultingToSeths() {
        let key = JuliaClient.endpointKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(JuliaClient.configuredEndpoint, "https://hidden-kudu-77.convex.cloud")
        UserDefaults.standard.set("https://other-thing-12.convex.cloud", forKey: key)
        XCTAssertEqual(try JuliaClient().endpoint.absoluteString, "https://other-thing-12.convex.cloud")
        XCTAssertThrowsError(try JuliaClient(endpoint: "http://evil.example.com"))
    }
}

final class ReportStabilityTests: XCTestCase {
    func testAnUnreadableScreenKeepsTheAskItHad() {
        var reporter = JuliaReporter(latch: 10, reassert: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        let asked = JuliaReport(externalId: JuliaReporter.externalId(key: "tab", prompt: "Allow x?\n› 1. Yes"), project: "p", subtask: "s",
            jumpHandle: "with-tty", prompt: "Allow x?\n› 1. Yes", harness: "codex", tabKey: "tab")
        let blind = JuliaReport(externalId: JuliaReporter.externalId(key: "tab", prompt: nil), project: "p", subtask: "s",
            jumpHandle: "no-tty", prompt: nil, harness: "codex", tabKey: "tab")
        XCTAssertEqual(reporter.observe([asked], now: t0).report, [asked])
        XCTAssertEqual(reporter.observe([blind], now: t0.addingTimeInterval(2)), JuliaReportDiff(), "no second row, no handle flap")
        XCTAssertEqual(reporter.observe([blind], now: t0.addingTimeInterval(20)).resolve, [], "still held: the tab is still asking")
        let next = JuliaReport(externalId: JuliaReporter.externalId(key: "tab", prompt: "Allow y?\n› 1. Yes"), project: "p", subtask: "s",
            jumpHandle: "with-tty", prompt: "Allow y?\n› 1. Yes", harness: "codex", tabKey: "tab")
        let d = reporter.observe([next], now: t0.addingTimeInterval(21))
        XCTAssertEqual(d.report, [next], "a readable new question is a new ask")
        XCTAssertEqual(reporter.observe([next], now: t0.addingTimeInterval(40)).resolve, [asked.externalId])
    }
}

final class JumpHandleStabilityTests: XCTestCase {
    @MainActor func testTheSameTabAlwaysMintsTheSameHandle() throws {
        let entry = WindowEntry(id: "792:window:1", pid: 792, appName: "Terminal", title: "x — [ ! ] Action Required | t — codex",
            icon: nil, element: AXUIElementCreateApplication(792), minimized: false, hidden: false, terminal: true)
        let d = try XCTUnwrap(AttentionDestination(entry: entry, launch: Date(timeIntervalSince1970: 1_791_000_000.123), tty: "ttys040"))
        let handles = Set((0..<200).compactMap { _ in JuliaJumpHandle.encode(d) })
        XCTAssertEqual(handles.count, 1, "a handle that changes per encode re-sends every report every scan")
    }
}

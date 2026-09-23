import Combine
import ConvexMobile
import Foundation

// THE HANDS ARE NO LONGER DEAF. prefrontal/1 (convexos/packages/prefrontal-contract): an
// act on a window that lives on THIS Mac — focus, foreground, type, media, a new
// terminal — is a `commands` row addressed to this machineId. Velocity SUBSCRIBES to the
// queue (nothing here polls), takes each row, runs it through the same velocity://
// handling the same-machine fast path uses, and settles with a RECEIPT. His words in a
// `type` command are never logged and never kept: the server clears them on settle.
//
// A RECEIPT IS WHAT WAS SEEN DONE (docs/PREFRONTAL-NEXT.md §5). `perform` is async and
// resolves only once the act's outcome was observed — the window topmost, the tty in
// front, the keys posted, the room silent — and returns HOW it knows (a method from the
// contract's closed list) or WHY not (an ErrorClass and a sentence). `settle` is sent
// after that, never before: the server refuses ok:true without a method.

/// Root function names from the contract's FUNCTIONS table. Every call carries the
/// paired surface's `token`.
enum PrefrontalFunction {
    static let register = "prefrontal:register"
    static let machineState = "prefrontal:machineState"
    static let observe = "prefrontal:observe"
    static let now = "prefrontal:now"
    static let commandsForMachine = "prefrontal:commandsForMachine"
    static let take = "prefrontal:take"
    static let settle = "prefrontal:settle"
    static let protocolVersion = "prefrontal/1"
    /// What Velocity can sense and do on a Mac (contract `Capability`).
    static let capabilities = ["windows", "terminals", "transcripts", "tty", "focus", "foreground", "type", "media", "terminal.open", "now"]
}

/// The outcome of one act, as the contract's Receipt carries it: HOW it was seen done
/// (`VerificationMethod` + what was observed) or WHY it was not (`ErrorClass` + why).
enum ActReceipt: Equatable {
    /// z-order · app-activated · tty-front · keys-posted · prompt-echoed · prompt-cleared · audio-silent · tty-appeared · self
    case verified(method: String, observed: String)
    /// invalid · unavailable · unsupported · stale · conflict · timeout · uncertain
    case failed(class: String, why: String)

    var ok: Bool { if case .verified = self { return true } else { return false } }
    /// One line for the log — never his words.
    var line: String {
        switch self {
        case .verified(let method, let observed): return "done · \(method) · \(observed.prefix(120))"
        case .failed(let cls, let why): return "FAILED · \(cls) · \(why.prefix(160))"
        }
    }
    /// The settle mutation's fields (beside token + id).
    var settleFields: [String: ConvexEncodable?] {
        switch self {
        case .verified(let method, let observed):
            return ["ok": true, "verification": ["method": method, "observed": String(observed.prefix(300))] as [String: ConvexEncodable?]]
        case .failed(let cls, let why):
            return ["ok": false, "error": String(why.prefix(300)), "failure": ["class": cls, "why": String(why.prefix(300))] as [String: ConvexEncodable?]]
        }
    }
}

/// One queued act (contract `Command`). Args are all optional; the kind says which matter.
struct PrefrontalCommand: Decodable, Equatable {
    struct Args: Decodable, Equatable {
        var handle: String?
        var sig: String?
        var project: String?
        var windowKeys: [String]?
        var text: String?
        var enter: Bool?
        var path: String?
        var pause: Bool?
        var create: Bool?
        /// The ring's colour: the state's (blue = an answer, orange = it needs him).
        var glow: String?
        /// For `approve`: which harness's dialog is asking (the report read it).
        var harness: String?
        /// For `label`: the screen point "x,y" (a string — numbers drop in nested args).
        var point: String?
    }
    let id: String
    let machineId: String
    let kind: String
    let args: Args
    let status: String
    let createdAt: Double?
    let expiresAt: Double?

    /// The same-machine URL for this act — one mapping, so a command and a click do the
    /// same thing. Nil for `wake` / `doctor` (nothing to open: being here to settle it IS
    /// the answer).
    var velocityURL: URL? {
        func q(_ name: String, _ value: String?) -> String? {
            guard let value else { return nil }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+")
            return name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }
        var host: String
        var items: [String?] = []
        switch kind {
        case "focus":
            // A handle names the exact tab (the folder rides along as its fallback); a
            // window key names one window; a folder alone means "the terminal in it".
            host = "focus"
            if args.handle != nil { items = [q("handle", args.handle), q("sig", args.sig)] }
            else if let key = args.windowKeys?.first { items = [q("project", args.project), q("window", key)] }
            else { items = [q("sig", args.sig)] }
        case "foreground":
            host = "foreground"
            guard args.project != nil else { return nil }
            items = [q("project", args.project), q("windows", args.windowKeys?.joined(separator: ","))]
        case "label":
            host = "label"
            items = [q("project", args.project), q("point", args.point)]
        case "approve":
            // A "Yes" to the question on that tab's screen — Velocity picks the harness's keys.
            host = "approve"
            items = [q("handle", args.handle), q("sig", args.sig), q("harness", args.harness)]
        case "type":
            host = "type"
            guard args.text != nil else { return nil }
            items = [q("text", args.text), q("enter", args.enter == true ? "1" : nil), q("handle", args.handle), q("sig", args.sig)]
        case "media":
            host = "media"
            items = [args.pause == false ? "resume=1" : "pause=1"]
        case "terminal.open":
            host = "terminal"
            items = [q("path", args.path), args.create == true ? "create=1" : nil]
        default: return nil
        }
        if kind == "focus" || kind == "foreground" || kind == "type" { items.append(q("glow", args.glow)) }
        let query = items.compactMap { $0 }.joined(separator: "&")
        return URL(string: "velocity://" + host + (query.isEmpty ? "" : "?" + query))
    }
}

@MainActor final class PrefrontalLink {
    /// Runs one command on this Mac and resolves with its receipt once the outcome was seen.
    var perform: ((PrefrontalCommand) async -> ActReceipt)?
    private let client: ConvexClient
    private var subscription: AnyCancellable?
    private var token = ""
    private var handled: Set<String> = []
    /// The newest frame of the queue — the same-machine nudge looks here first.
    private var latest: [PrefrontalCommand] = []
    private var retryDelay: Duration = .seconds(30)
    private var retryTask: Task<Void, Never>?

    init(endpoint: URL) {
        client = ConvexClient(deploymentUrl: endpoint.absoluteString)
    }

    /// Subscribe to this machine's queue. Called on pairing and on every paired launch.
    func start(token: String) {
        self.token = token
        retryTask?.cancel(); retryTask = nil
        subscription?.cancel()
        let machineId = MachineIdentity.machineId
        JuliaLog.note("prefrontal: subscribing to commands for machine \(machineId.prefix(8))")
        subscription = client.subscribe(to: PrefrontalFunction.commandsForMachine, with: ["token": token, "machineId": machineId], yielding: [PrefrontalCommand].self)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                guard case .failure(let error) = completion else { return }
                MainActor.assumeIsolated { self?.lost(error) }
            }, receiveValue: { [weak self] commands in
                MainActor.assumeIsolated { self?.receive(commands) }
            })
    }

    func stop() {
        subscription?.cancel(); subscription = nil
        retryTask?.cancel(); retryTask = nil
        handled = []; latest = []; token = ""
    }

    /// A subscription ends only when the server refuses it (the function is not there yet,
    /// the token is gone). Come back later, slower each time — the websocket's own
    /// reconnects never end the publisher, so this is not a poll in the steady state.
    private func lost(_ error: Error) {
        JuliaLog.note("prefrontal: command subscription ended: \(error.localizedDescription.prefix(200)) — retrying in \(retryDelay)")
        subscription = nil
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(600))
        let token = self.token
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.token == token, !token.isEmpty else { return }
            self.start(token: token)
        }
    }

    private func receive(_ commands: [PrefrontalCommand]) {
        retryDelay = .seconds(30)
        latest = commands
        let queued = commands.filter { $0.status == "queued" && !handled.contains($0.id) }
        // Forget ids the queue no longer carries (settled rows leave the subscription).
        let live = Set(commands.map(\.id))
        handled = handled.intersection(live)
        for command in queued.sorted(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }) {
            handled.insert(command.id)
            run(command)
        }
    }

    /// THE SAME-MACHINE NUDGE: `velocity://run?id=<commandId>` from Julia.app on this Mac.
    /// The row is the act; the URL only shortens the wait (and launches Velocity when it
    /// is not running). Idempotent with the subscription: whichever arrives first takes
    /// the row and runs it; the other sees `took: false` and does nothing. When the row is
    /// not in the last frame yet, the SUBSCRIPTION runs it a moment later — nothing is
    /// marked handled here for a row not in hand (a re-read of the query hands back the
    /// client's cached frame, which is exactly the stale one; measured: the row then sat
    /// unhandled until it expired).
    func nudge(id: String) {
        guard !token.isEmpty else { JuliaLog.note("act run \(id.prefix(8)): not paired — the row will expire unpicked"); return }
        if handled.contains(id) { JuliaLog.note("act run \(id.prefix(8)): already in hand"); return }
        guard let command = latest.first(where: { $0.id == id }), command.status == "queued" else {
            JuliaLog.note("act run \(id.prefix(8)): not in the last frame yet — the subscription runs it")
            return
        }
        handled.insert(id)
        run(command)
    }

    private func run(_ command: PrefrontalCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let took: Bool
            do {
                let r: TakeResult = try await client.mutation(PrefrontalFunction.take, with: ["token": token, "id": command.id])
                took = r.took ?? false
                if !took { JuliaLog.note("act \(command.kind) \(command.id.prefix(8)): \(r.status) already — nothing to do"); return }
            } catch {
                JuliaLog.note("prefrontal: take \(command.id) failed: \(error.localizedDescription.prefix(200))")
                return
            }
            // What was done, never what was said: a type's text is not logged.
            JuliaLog.note("act \(command.kind) \(command.id.prefix(8)) taken\(command.args.sig.map { " sig=\($0)" } ?? "")\(command.args.project.map { " project=\($0)" } ?? "")")
            // THE RECEIPT COMES FROM THE OUTCOME: settle only after perform resolved.
            let receipt = await perform?(command) ?? .failed(class: "unsupported", why: "Velocity has no hands wired for that.")
            JuliaLog.note("act \(command.kind) \(command.id.prefix(8)) receipt: \(receipt.line)")
            var fields = receipt.settleFields
            fields["token"] = token
            fields["id"] = command.id
            // Settle answers `{status}`; the result-less overload decodes a String and would
            // report "failed" for a settle that took (measured: "data couldn't be read").
            do { let r: TakeResult = try await client.mutation(PrefrontalFunction.settle, with: fields); if r.status != "done" && r.status != "failed" { JuliaLog.note("prefrontal: settle \(command.id.prefix(8)) → \(r.status)") } }
            catch { JuliaLog.note("prefrontal: settle \(command.id.prefix(8)) failed: \(error.localizedDescription.prefix(200))") }
        }
    }

    private struct TakeResult: Decodable { let status: String; let took: Bool? }
}

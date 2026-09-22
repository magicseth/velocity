import Combine
import ConvexMobile
import Foundation

// THE HANDS ARE NO LONGER DEAF. prefrontal/1 (convexos/packages/prefrontal-contract): an
// act on a window that lives on THIS Mac — focus, foreground, type, media, a new
// terminal — is a `commands` row addressed to this machineId. Velocity SUBSCRIBES to the
// queue (nothing here polls), takes each row, runs it through the same velocity://
// handling the same-machine fast path uses, and settles with a receipt. His words in a
// `type` command are never logged and never kept: the server clears them on settle.

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
    }
    let id: String
    let machineId: String
    let kind: String
    let args: Args
    let status: String
    let createdAt: Double?
    let expiresAt: Double?

    /// The same-machine URL for this act — one mapping, so a command and a click do the
    /// same thing. Nil for `wake` (nothing to do: being here to settle it IS awake).
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
        case "type":
            host = "type"
            guard args.text != nil else { return nil }
            items = [q("text", args.text), q("enter", args.enter == true ? "1" : nil), q("handle", args.handle), q("sig", args.sig)]
        case "media":
            host = "media"
            items = [args.pause == false ? "resume=1" : "pause=1"]
        case "terminal.open":
            host = "terminal"
            items = [q("path", args.path)]
        default: return nil
        }
        let query = items.compactMap { $0 }.joined(separator: "&")
        return URL(string: "velocity://" + host + (query.isEmpty ? "" : "?" + query))
    }
}

@MainActor final class PrefrontalLink {
    /// Runs one command on this Mac; nil = it was dispatched, a string = why not.
    var perform: ((PrefrontalCommand) -> String?)?
    private let client: ConvexClient
    private var subscription: AnyCancellable?
    private var token = ""
    private var handled: Set<String> = []
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
        handled = []; token = ""
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
        let queued = commands.filter { $0.status == "queued" && !handled.contains($0.id) }
        // Forget ids the queue no longer carries (settled rows leave the subscription).
        let live = Set(commands.map(\.id))
        handled = handled.intersection(live)
        for command in queued.sorted(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }) {
            handled.insert(command.id)
            run(command)
        }
    }

    private func run(_ command: PrefrontalCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await client.mutation(PrefrontalFunction.take, with: ["token": token, "id": command.id])
            } catch {
                JuliaLog.note("prefrontal: take \(command.id) failed: \(error.localizedDescription.prefix(200))")
                return
            }
            // What was done, never what was said: a type's text is not logged.
            JuliaLog.note("prefrontal: \(command.kind) \(command.id.prefix(8))\(command.args.sig.map { " sig=\($0)" } ?? "")\(command.args.project.map { " project=\($0)" } ?? "")")
            let problem: String? = command.kind == "wake" ? nil : (perform?(command) ?? "Velocity has no hands wired for that.")
            var receipt: [String: ConvexEncodable?] = ["token": token, "id": command.id, "ok": problem == nil]
            if let problem { receipt["error"] = String(problem.prefix(300)) }
            do { try await client.mutation(PrefrontalFunction.settle, with: receipt) }
            catch { JuliaLog.note("prefrontal: settle \(command.id) failed: \(error.localizedDescription.prefix(200))") }
        }
    }
}

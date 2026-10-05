import Foundation
import JevVoiceCore

/// JSON-RPC seam the gate forwards through — satisfied by the shared
/// `CuaConnection` at integration, by a stub in tests.
protocol DriverToolCalling: Sendable {
    func callResult(_ name: String, arguments: [String: JSONValue]) async throws -> CuaToolResult
    func tools() async throws -> [JSONValue]
}

extension CuaConnection: DriverToolCalling {
    func callResult(_ name: String, arguments: [String: JSONValue]) async throws -> CuaToolResult {
        try await callResult(name, arguments: arguments, timeout: 30)
    }
}

/// Per-(agent, turn) consent gate in front of the driver's MCP surface —
/// Clicky's `ClickyComputerUseGate`. Observation calls pass through
/// untouched; every `ConsentContract.requiresConsent` call is refused with a
/// `blocked_by_consent` tool error until the app approves that turn's
/// `ConsentRequest`. Approving one (agent, turn) never arms another.
/// Integration mints a real turnID per voice task — a nil-turn approval is
/// therefore one-shot (spent by the first forwarded input call) and a
/// nil-turn denial expires after `nilTurnDenialTTL` so it may re-ask.
///
/// `ConsentGating` is synchronous, so state lives behind a lock rather than
/// actor isolation; the lock is never held across an `await`.
final class ComputerUseGate: ConsentGating, @unchecked Sendable {
    private struct ConsentKey: Hashable {
        var agent: String?
        var turn: String?
    }

    /// Label-ish arguments re-checked against the caller's deny list.
    private static let labelArguments = ["elementLabel", "label", "name"]
    /// Cap on live asks — `requests` only holds pendings, but a flooding
    /// caller can mint one per distinct (agent, turn) key.
    private static let requestLimit = 128
    /// Session lifecycle is host-owned — the runtime mints one driver
    /// session per agent transport, and an agent ending (or escalating) a
    /// session would strand its own later calls on a tombstoned label.
    private static let agentDeniedTools: Set<String> = [
        "start_session", "end_session", "escalate_session"
    ]
    /// pid → app identity resolution rides `list_apps`; the result is stable
    /// on a lease timescale, so a short cache avoids a driver roundtrip on
    /// every forwarded input call.
    private static let pidIdentityTTL: TimeInterval = 30

    /// Per-caller driver resolution — each agent gets its own CuaConnection
    /// (its own embedded daemon), so the gate must ask per call rather than
    /// hold one fixed transport.
    private let driverFor: @Sendable (String?) -> (any DriverToolCalling)?
    /// Shared lane arbitration — voice tasks and agent calls serialize on
    /// the same app/focus/pasteboard leases. Nil keeps the gate usable in
    /// isolation (tests, single-slot embedders).
    private let lanes: (any AgentLaneLeasing)?
    private let nilTurnDenialTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var state = State()

    init(driver: any DriverToolCalling, lanes: (any AgentLaneLeasing)? = nil,
         nilTurnDenialTTL: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.driverFor = { _ in driver }
        self.lanes = lanes
        self.nilTurnDenialTTL = nilTurnDenialTTL
        self.now = now
    }

    init(driverFor: @escaping @Sendable (String?) -> (any DriverToolCalling)?,
         lanes: (any AgentLaneLeasing)? = nil,
         nilTurnDenialTTL: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.driverFor = driverFor
        self.lanes = lanes
        self.nilTurnDenialTTL = nilTurnDenialTTL
        self.now = now
    }

    /// The coordinator reports the agent's live turn whenever Codex starts
    /// one; consent arms (agent, turn) pairs, never a bare agent. A turn
    /// change evicts the agent's asks and decisions for every other turn —
    /// dead-turn pendings must not poison `pending()` or the bare "yes" flow.
    func setActiveTurn(_ turnID: String?, agentSlug: String?) {
        locked { $0.setActiveTurn(turnID, agentSlug: agentSlug) }
    }

    /// Per-caller label deny list — the coordinator copies `DriveTask.deny`
    /// (or the voice path's equivalent) here before arming a turn. Entries
    /// are normalized: a whitespace-wrapped label would otherwise substring-
    /// match almost nothing and silently weaken the ban.
    func setDenyList(_ labels: [String], agentSlug: String?) {
        locked {
            $0.denyLists[agentSlug] = labels
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// The driver session label this caller's calls should carry. The runtime
    /// registers the label it actually passed to `start_session` — a session
    /// label is owned by its transport lease, so when a lease dies the label
    /// is tombstoned and can never be revived by another transport. Reusing a
    /// tombstoned label makes the daemon refuse every call, so the runtime
    /// mints a unique label per connection and must bind it here.
    func setSessionLabel(_ label: String, agentSlug: String?) {
        locked { $0.sessionLabels[agentSlug] = label }
    }

    /// tools/call entry — never throws; refusals arrive as `isError` tool
    /// results carrying `structuredContent.refusal.code`, the same envelope
    /// the driver itself uses, so the agent reads the message and keeps
    /// working with observation tools.
    func callTool(_ name: String, arguments: JSONValue, agentSlug: String?) async -> JSONValue {
        var args = arguments.object ?? [:]
        if ConsentContract.requestsDesktopScope(arguments) {
            return Self.refusal("scope_refused",
                "refused: desktop scope moves the user's real pointer. Drive a window_id instead.")
        }
        if agentSlug != nil, Self.agentDeniedTools.contains(name) {
            return Self.refusal("host_owned_tool",
                "refused: \(name) manages the driver's session lifecycle — sessions are owned by the host, not agents. Your session is already bound; call the tool you need directly.")
        }
        let gated = ConsentContract.requiresConsent(name)
        if gated {
            if let hit = deniedLabel(in: args, agentSlug: agentSlug) {
                return Self.refusal("denied_label",
                    "refused: \"\(hit)\" is on this caller's deny list — pick a different element or report the step as blocked.")
            }
            // bring_to_front is exempt from the delivery_mode policy: the
            // driver treats that tool as inherently foreground (tool.rs), so
            // a caller honestly passing "foreground" would be refused and our
            // injected "background" is ignored anyway.
            if name != "bring_to_front",
               let mode = args["delivery_mode"], mode != .null, mode != .string(ConsentContract.requiredDeliveryMode) {
                return Self.refusal("delivery_mode_required",
                    "refused: delivery_mode must be \"\(ConsentContract.requiredDeliveryMode)\" or omitted — input never steals focus.")
            }
            do {
                // Permit + consume in one lock: a nil-turn approval is spent
                // the moment this call forwards, so one "yes" never arms a
                // session and racing calls can't share a single approval.
                try locked { state in
                    let key = ConsentKey(agent: agentSlug, turn: state.activeTurns[agentSlug] ?? nil)
                    try state.assertPermitted(tool: name, key: key,
                        now: now(), nilTurnDenialTTL: nilTurnDenialTTL)
                    if key.turn == nil { state.approved.remove(key) }
                }
            } catch GateError.blockedByConsent(let summary) {
                return Self.refusal("blocked_by_consent", summary)
            } catch {
                return Self.refusal("blocked_by_consent",
                    "computer-use consent is required: the user has not approved input for this turn. Emit a <COMPUTER_USE_REQUEST> line to ask, then wait — observation tools still work meanwhile.")
            }
            if name != "bring_to_front" {
                args["delivery_mode"] = .string(ConsentContract.requiredDeliveryMode)
            }
        }
        // Lane arbitration: input calls take the target app's lease for the
        // call's duration, and focus/pasteboard-touching tools take those
        // lanes too — the registry serializes agents against the voice
        // runtime's work on the same resources. A lease that can't be taken
        // (a cancelled call) fails closed rather than dispatching unsorted.
        var acquiredWorkID: String?
        if let lanes {
            // Full UUID, not a prefix — a workID collision would let one
            // call's releaseAll free another live call's lanes mid-dispatch.
            let workID = "agent-\(agentSlug ?? "jev")-gate-\(UUID().uuidString.lowercased())"
            do {
                var held = false
                if gated, let identity = await appIdentity(for: name, args: args, agentSlug: agentSlug) {
                    try await lanes.acquire(app: identity, pid: args["pid"]?.integer, workID: workID)
                    held = true
                }
                // Only gated calls take the focus lane — a read carrying a
                // forged delivery_mode must not serialize on the global
                // lane. The pasteboard stays unconditional: clipboard_read
                // is observation yet still races a held clipboard write.
                if gated, Self.requestsFocus(name: name, args: args) {
                    try await lanes.acquireFocus(workID: workID)
                    held = true
                }
                if Self.touchesPasteboard(name: name, args: args) {
                    try await lanes.acquirePasteboard(workID: workID)
                    held = true
                }
                if held { acquiredWorkID = workID }
            } catch {
                await lanes.releaseAll(workID: workID)
                return Self.error("lane_unavailable",
                    "\(name) could not be scheduled — the target's lane is unavailable. Retry once; if it persists, report the step as blocked.")
            }
        }
        // A caller cancelled after leasing but before dispatch must not land
        // input nobody is watching — hand the lease back and fail closed.
        if Task.isCancelled {
            if let lanes, let acquiredWorkID {
                await lanes.releaseAll(workID: acquiredWorkID)
            }
            return Self.error("cancelled", "\(name) was cancelled before it could run.")
        }
        if let agentSlug {
            // Per-agent driver session — the badge + session-colored cursor
            // the driver renders is this agent's visible identity. The arg
            // is rewritten unconditionally: a caller-supplied label would
            // let one agent drive under another's identity.
            let label = locked { $0.sessionLabels[agentSlug] ?? ("agent-" + agentSlug) }
            args["session"] = .string(label)
        }
        let result = await forward(name, args, agentSlug: agentSlug)
        if let lanes, let acquiredWorkID {
            await lanes.releaseAll(workID: acquiredWorkID)
        }
        return result
    }

    /// One endpoint per agent — the coordinator writes `Endpoint.url`/`.token`
    /// into the agent's `mcp_servers` config, binding every call to its slug.
    /// The driver resolves per request so each agent's calls run on its own
    /// connection; an unminted transport reads as `.closed`, which codex
    /// treats as "server broken" — endpoints only go live after connect.
    func server(agentSlug: String?, token: String? = nil) -> LoopbackMCPServer {
        LoopbackMCPServer(serverName: "jev-computer-use", token: token,
            tools: { [driverFor] in
                guard let driver = driverFor(agentSlug) else { throw DriverConnectionError.closed }
                return try await driver.tools()
            },
            onCall: { name, args in await self.callTool(name, arguments: args, agentSlug: agentSlug) })
    }

    // MARK: ConsentGating

    func pending() -> [ConsentRequest] {
        locked { $0.requests.values.filter { $0.state == .pending }.sorted { $0.id < $1.id } }
    }

    func approve(_ request: ConsentRequest) {
        locked { state in
            let key = ConsentKey(agent: request.agentSlug, turn: request.turnID)
            state.approved.insert(key)
            state.denied[key] = nil
            state.asked.remove(key)
            state.resolve(request)
        }
    }

    func deny(_ request: ConsentRequest) {
        locked { state in
            let key = ConsentKey(agent: request.agentSlug, turn: request.turnID)
            state.denied[key] = now()
            state.approved.remove(key)
            state.asked.remove(key)
            state.resolve(request)
        }
    }

    /// Observation is always permitted. Anything `requiresConsent` gates needs
    /// an approved (agent, turn); the first refusal records the pending ask so
    /// a bare voice "yes" or a consent card can resolve it.
    func assertPermitted(tool: String, agentSlug: String?, turnID: String?) throws {
        try locked { state in
            try state.assertPermitted(tool: tool, key: ConsentKey(agent: agentSlug, turn: turnID),
                now: now(), nilTurnDenialTTL: nilTurnDenialTTL)
        }
    }

    /// Same check keyed to the agent's live turn — the resolution callTool
    /// performs internally, exposed for tool surfaces that execute work
    /// outside a tools/call envelope (jev-use drive_until). A nil-turn
    /// approval is spent exactly like callTool spends it: one "yes" arms one
    /// call, never a standing grant.
    func assertPermittedNow(tool: String, agentSlug: String?) throws {
        try locked { state in
            let key = ConsentKey(agent: agentSlug, turn: state.activeTurns[agentSlug] ?? nil)
            try state.assertPermitted(tool: tool, key: key,
                now: now(), nilTurnDenialTTL: nilTurnDenialTTL)
            if key.turn == nil { state.approved.remove(key) }
        }
    }

    // MARK: Forwarding

    private func forward(_ name: String, _ args: [String: JSONValue], agentSlug: String?) async -> JSONValue {
        guard let driver = driverFor(agentSlug) else {
            return Self.error("driver_unavailable",
                "This agent's driver connection is not up yet — wait a moment and retry.")
        }
        do {
            let result = try await driver.callResult(name, arguments: args)
            return .object(["structuredContent": result.structured, "content": .array(result.content)])
        } catch let error as CuaUncertainOutcome {
            return Self.error("uncertain_outcome",
                "\(name) reported a partial or uncertain outcome; an effect may have occurred. Inspect the target before retrying.",
                structured: error.result)
        } catch DriverConnectionError.toolRefused(_, let code, let detail) {
            return Self.error(code, detail.isEmpty ? "The driver refused \(name)." : detail,
                structured: .object(["status": .string("refused"), "code": .string(code),
                                     "refusal": .object(["code": .string(code)])]))
        } catch {
            return Self.error("driver_error",
                (error as? LocalizedError)?.errorDescription ?? "The driver call failed.")
        }
    }

    /// Lease identity for a forwarded call's target: a pid resolves to its
    /// app's bundle/name via `list_apps` (cached — process identity is
    /// stable on a lease timescale), launch/kill args carry the app's own
    /// spelling, and a bare window_id falls back to a window-scoped key —
    /// window ids are globally unique, so every caller of the same window
    /// still serializes.
    private func appIdentity(for name: String, args: [String: JSONValue],
                             agentSlug: String?) async -> String? {
        if let pid = args["pid"]?.integer { return await pidIdentity(pid, agentSlug: agentSlug) }
        for key in ["application", "bundle_id", "app", "app_name"] {
            if let value = args[key]?.string, !value.isEmpty { return value }
        }
        if ["launch_app", "kill_app"].contains(name),
           let value = args["name"]?.string, !value.isEmpty { return value }
        if let wid = args["window_id"]?.integer { return "window-\(wid)" }
        return nil
    }

    private func pidIdentity(_ pid: Int, agentSlug: String?) async -> String {
        if let cached = locked({ $0.pidIdentities[pid] }),
           now().timeIntervalSince(cached.at) < Self.pidIdentityTTL {
            return cached.identity
        }
        var identity = "pid-\(pid)"
        if let driver = driverFor(agentSlug),
           let result = try? await driver.callResult("list_apps", arguments: [:]),
           let match = result.structured["apps"]?.array?.first(where: { $0["pid"]?.integer == pid }) {
            identity = match["bundle_id"]?.string ?? match["name"]?.string ?? identity
        }
        locked { $0.pidIdentities[pid] = (identity, now()) }
        return identity
    }

    /// Focus-class calls mutate what the user is looking at — raising a
    /// window, walking a menu bar, launching an app, or any caller that
    /// somehow still carries foreground delivery (bring_to_front is exempt
    /// from the forced-background rewrite, so the arg must be checked, not
    /// assumed gone).
    private static func requestsFocus(name: String, args: [String: JSONValue]) -> Bool {
        if ["bring_to_front", "invoke_menu", "launch_app"].contains(name) { return true }
        return args["delivery_mode"]?.string?.lowercased() == "foreground"
    }

    /// The pasteboard is a single shared resource — ⌘V delivered while
    /// another lane holds a clipboard write lands the wrong payload.
    private static func touchesPasteboard(name: String, args: [String: JSONValue]) -> Bool {
        if ["clipboard_write", "clipboard_read"].contains(name) { return true }
        guard name == "hotkey" else { return false }
        var keys = (args["keys"]?.array?.compactMap(\.string) ?? [])
        if let chord = args["chord"]?.string { keys.append(chord) }
        if let single = args["key"]?.string { keys.append(single) }
        let parts = keys.flatMap {
            $0.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let set = Set(parts)
        return !set.isDisjoint(with: ["cmd", "command", "meta", "⌘"])
            && !set.isDisjoint(with: ["c", "x", "v"])
    }

    private func deniedLabel(in args: [String: JSONValue], agentSlug: String?) -> String? {
        locked { state in
            guard let deny = state.denyLists[agentSlug], !deny.isEmpty else { return nil }
            for key in Self.labelArguments {
                guard let value = args[key]?.string else { continue }
                let lowered = value.lowercased()
                if let hit = deny.first(where: { lowered.contains($0.lowercased()) }) { return hit }
            }
            return nil
        }
    }

    private func locked<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    private static func refusal(_ code: String, _ message: String) -> JSONValue {
        error(code, message, structured: .object([
            "status": .string("refused"), "code": .string(code),
            "refusal": .object(["code": .string(code), "message": .string(message)])
        ]))
    }

    private static func error(_ code: String, _ message: String, structured: JSONValue? = nil) -> JSONValue {
        var body = structured?.object ?? ["code": .string(code)]
        if body["code"] == nil { body["code"] = .string(code) }
        return .object([
            "isError": .bool(true),
            "structuredContent": .object(body),
            "content": .array([.object(["type": .string("text"), "text": .string(message)])])
        ])
    }

    /// All mutable state on one value so `locked` closures get inout access.
    private struct State {
        var requests: [String: ConsentRequest] = [:]
        var approved: Set<ConsentKey> = []
        var denied: [ConsentKey: Date] = [:]
        var asked: Set<ConsentKey> = []
        var activeTurns: [String?: String] = [:]
        var denyLists: [String?: [String]] = [:]
        var sessionLabels: [String?: String] = [:]
        var pidIdentities: [Int: (identity: String, at: Date)] = [:]

        mutating func setActiveTurn(_ turnID: String?, agentSlug: String?) {
            guard activeTurns[agentSlug] != turnID else { return }
            activeTurns[agentSlug] = turnID
            requests = requests.filter { $0.value.agentSlug != agentSlug || $0.value.turnID == turnID }
            approved = approved.filter { $0.agent != agentSlug || $0.turn == turnID }
            asked = asked.filter { $0.agent != agentSlug || $0.turn == turnID }
            denied = denied.filter { $0.key.agent != agentSlug || $0.key.turn == turnID }
        }

        mutating func assertPermitted(tool: String, key: ConsentKey, now: Date,
                                      nilTurnDenialTTL: TimeInterval) throws {
            guard ConsentContract.requiresConsent(tool) else { return }
            // Standing grant: the always-allow setting pre-approves every
            // (agent, turn) — Clicky's always-allow variant. Deny lists,
            // scope refusals and delivery-mode policy still apply upstream.
            guard !CuaStandingGrants.computerUseInput else { return }
            if approved.contains(key) { return }
            if let deniedAt = denied[key] {
                if key.turn == nil, now.timeIntervalSince(deniedAt) >= nilTurnDenialTTL {
                    denied[key] = nil
                } else {
                    throw GateError.blockedByConsent(summary:
                        "computer-use consent was denied for this turn — do not retry input tools; observation tools still work.")
                }
            }
            if asked.insert(key).inserted {
                let ask = ConsentRequest(agentSlug: key.agent, turnID: key.turn,
                    summary: "\(key.agent ?? "Jev") wants computer input for this turn.",
                    reason: "\(tool) requires user approval before it can run.")
                requests[ask.id] = ask
                pruneRequests()
            }
            throw GateError.blockedByConsent(summary:
                "computer-use consent is required: the user has not approved input for this turn. Emit a <COMPUTER_USE_REQUEST> line to ask, then wait — observation tools still work meanwhile.")
        }

        /// Resolved asks leave `requests` entirely so `pending()` only ever
        /// holds live asks and resolved history can't accumulate.
        mutating func resolve(_ request: ConsentRequest) {
            requests[request.id] = nil
            for (id, existing) in requests
                where existing.agentSlug == request.agentSlug && existing.turnID == request.turnID {
                requests[id] = nil
            }
        }

        private mutating func pruneRequests() {
            guard requests.count > ComputerUseGate.requestLimit else { return }
            for id in requests.keys.sorted().prefix(requests.count - ComputerUseGate.requestLimit) {
                requests[id] = nil
            }
        }
    }
}

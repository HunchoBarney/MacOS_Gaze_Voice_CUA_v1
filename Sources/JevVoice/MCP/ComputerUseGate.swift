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
/// untouched; every `ConsentContract.inputTools` call is refused with a
/// `blocked_by_consent` tool error until the app approves that turn's
/// `ConsentRequest`. Approving one (agent, turn) never arms another.
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

    private let driver: any DriverToolCalling
    private let lock = NSLock()
    private var state = State()

    init(driver: any DriverToolCalling) { self.driver = driver }

    /// The coordinator reports the agent's live turn whenever Codex starts
    /// one; consent arms (agent, turn) pairs, never a bare agent.
    func setActiveTurn(_ turnID: String?, agentSlug: String?) {
        locked { $0.activeTurns[agentSlug] = turnID }
    }

    /// Per-caller label deny list — the coordinator copies `DriveTask.deny`
    /// (or the voice path's equivalent) here before arming a turn.
    func setDenyList(_ labels: [String], agentSlug: String?) {
        locked { $0.denyLists[agentSlug] = labels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    /// tools/call entry — never throws; refusals arrive as `isError` tool
    /// results carrying `structuredContent.refusal.code`, the same envelope
    /// the driver itself uses, so the agent reads the message and keeps
    /// working with observation tools.
    func callTool(_ name: String, arguments: JSONValue, agentSlug: String?) async -> JSONValue {
        var args = arguments.object ?? [:]
        if let scope = args["scope"]?.string, ConsentContract.refusedScopes.contains(scope) {
            return Self.refusal("scope_refused",
                "refused: \(scope) scope moves the user's real pointer. Drive a window_id instead.")
        }
        if ConsentContract.inputTools.contains(name) {
            if let hit = deniedLabel(in: args, agentSlug: agentSlug) {
                return Self.refusal("denied_label", "refused: \"\(hit)\" is on this caller's deny list.")
            }
            do {
                try assertPermitted(tool: name, agentSlug: agentSlug, turnID: activeTurn(agentSlug: agentSlug))
            } catch GateError.blockedByConsent(let summary) {
                return Self.refusal("blocked_by_consent", summary)
            } catch {
                return Self.refusal("blocked_by_consent",
                    "computer use input is off until the user allows this turn. Observation tools still work.")
            }
            if let mode = args["delivery_mode"], mode != .null, mode != .string(ConsentContract.requiredDeliveryMode) {
                return Self.refusal("delivery_mode_required",
                    "refused: delivery_mode must be \"\(ConsentContract.requiredDeliveryMode)\" — input never steals focus.")
            }
            args["delivery_mode"] = .string(ConsentContract.requiredDeliveryMode)
        }
        return await forward(name, args)
    }

    /// One endpoint per agent — the coordinator writes `Endpoint.url`/`.token`
    /// into the agent's `mcp_servers` config, binding every call to its slug.
    func server(agentSlug: String?, token: String? = nil) -> LoopbackMCPServer {
        LoopbackMCPServer(serverName: "jev-computer-use", token: token,
            tools: { [driver] in try await driver.tools() },
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
            state.denied.remove(key)
            state.resolve(request, mark: .approved)
        }
    }

    func deny(_ request: ConsentRequest) {
        locked { state in
            let key = ConsentKey(agent: request.agentSlug, turn: request.turnID)
            state.denied.insert(key)
            state.approved.remove(key)
            state.resolve(request, mark: .denied)
        }
    }

    /// Observation is always permitted. Input needs an approved (agent, turn);
    /// the first refusal records the pending ask so a bare voice "yes" or a
    /// consent card can resolve it.
    func assertPermitted(tool: String, agentSlug: String?, turnID: String?) throws {
        guard ConsentContract.inputTools.contains(tool) else { return }
        try locked { state in
            let key = ConsentKey(agent: agentSlug, turn: turnID)
            guard !state.approved.contains(key) else { return }
            if !state.denied.contains(key), state.asked.insert(key).inserted {
                let ask = ConsentRequest(agentSlug: agentSlug, turnID: turnID,
                    summary: "\(agentSlug ?? "Jev") wants computer input for this turn.",
                    reason: "\(tool) requires user approval before it can run.")
                state.requests[ask.id] = ask
            }
            throw GateError.blockedByConsent(summary: state.denied.contains(key)
                ? "computer use input was denied for this turn. Observation tools still work."
                : "computer use input is off until the user allows this turn. Observation tools still work.")
        }
    }

    // MARK: Forwarding

    private func forward(_ name: String, _ args: [String: JSONValue]) async -> JSONValue {
        do {
            let result = try await driver.callResult(name, arguments: args)
            return .object(["structuredContent": result.structured, "content": .array(result.content)])
        } catch let error as CuaUncertainOutcome {
            return Self.error("uncertain_outcome",
                "\(name) reported a partial or uncertain outcome; an effect may have occurred. Inspect the target before retrying.",
                structured: error.result)
        } catch DriverConnectionError.toolRefused(_, let code) {
            return Self.error(code, "The driver refused \(name).",
                structured: .object(["status": .string("refused"), "code": .string(code),
                                     "refusal": .object(["code": .string(code)])]))
        } catch {
            return Self.error("driver_error",
                (error as? LocalizedError)?.errorDescription ?? "The driver call failed.")
        }
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

    private func activeTurn(agentSlug: String?) -> String? {
        locked { $0.activeTurns[agentSlug] ?? nil }
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
        var denied: Set<ConsentKey> = []
        var asked: Set<ConsentKey> = []
        var activeTurns: [String?: String] = [:]
        var denyLists: [String?: [String]] = [:]

        mutating func resolve(_ request: ConsentRequest, mark: ConsentRequest.State) {
            var stored = request
            stored.state = mark
            requests[stored.id] = stored
            for (id, existing) in requests where existing.state == .pending
                && existing.agentSlug == request.agentSlug && existing.turnID == request.turnID {
                var copy = existing
                copy.state = mark
                requests[id] = copy
            }
        }
    }
}

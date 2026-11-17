import Foundation
import JevVoiceCore

/// The lane surface a `CuaConnectionPool` routes over. `CuaConnection` is
/// the production lane; tests substitute a recording fake — what the pool
/// pins down is routing discipline (writes → primary, reads → read lane,
/// one socket, one teardown), not the transport itself.
protocol CuaLane: Actor {
    /// `initialize` completed and the proxy is still alive.
    var connected: Bool { get async }
    /// The daemon socket this lane bound to, if any.
    var boundSocket: String? { get async }
    func connect(socket: String) async throws
    func call(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue
    func callResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> CuaToolResult
    func setAgentCursorEnabled(_ enabled: Bool, session: String) async
    func close() async
}

extension CuaConnection: CuaLane {}

/// Two `mcp --embedded` proxies bound to ONE shared daemon socket. The
/// daemon serializes every legacy `tools/call` per connection — the
/// `legacy_serial` mutex in mcp_envelope.rs — so a single transport can
/// never overlap an observe with a dispatch: a slow mutation starves every
/// read queued behind it. A second connection is the only way to read
/// while a write is in flight.
///
/// Lane discipline:
/// - `primary` carries mutations and any read the caller chooses.
/// - `readConnection` carries reads only. `callRead`/`callReadResult`
///   enforce `CuaConnection.isReadOnly` before touching the wire — a
///   mutation down this lane would run concurrently with a primary-lane
///   dispatch, and two in-flight GUI effects can race the same target.
///   The enforcement is argument-aware: `page` reads route, `page`
///   mutations refuse.
///
/// Shared lifecycle: `connect(socket:)` binds both lanes to the same
/// daemon, `close()` ends both, `connected` requires both alive. A dead
/// lane means replacing the pool wholesale — per `CuaConnection`, a
/// transport is never restarted in place.
///
/// Each lane keeps its own `pending`-request dictionary and FIFO write
/// tail inside its actor, so reads and writes interleave across lanes
/// with zero shared state — multiplexer correctness is per-connection and
/// unchanged.
actor CuaConnectionPool<Lane: CuaLane> {
    /// Mutations + reads — serialized per the daemon's per-connection
    /// legacy dispatch.
    let primary: Lane
    /// Read-only second transport — same daemon, real parallelism.
    /// Callers route through `callRead`/`callReadResult`; direct use must
    /// keep the read-only contract.
    let readConnection: Lane

    /// Memberwise — tests inject recording fakes here; production callers
    /// prefer `init(onToolCall:)` below.
    init(primary: Lane, readConnection: Lane) {
        self.primary = primary
        self.readConnection = readConnection
    }

    /// The production pair: two proxies on the pinned driver binary. The
    /// sick-daemon hook is wired by `CuaConnection.init`'s default — a
    /// refusal storm on either lane re-mints the shared daemon,
    /// token-scoped to the dead generation. Pass `onToolCall` for per-call
    /// telemetry; callers needing a custom sick-daemon hook construct lanes
    /// themselves via `init(primary:readConnection:)`.
    init(onToolCall: (@Sendable (String, Int?) -> Void)? = nil) where Lane == CuaConnection {
        primary = CuaConnection(onToolCall: onToolCall)
        readConnection = CuaConnection(onToolCall: onToolCall)
    }

    /// Binds BOTH lanes to the same daemon socket. One-shot per pool — a
    /// failed second bind closes the first so no proxy is stranded on a
    /// socket this pair will never serve.
    func connect(socket: String) async throws {
        do {
            try await primary.connect(socket: socket)
            try await readConnection.connect(socket: socket)
        } catch {
            await primary.close()
            await readConnection.close()
            throw error
        }
    }

    /// Both lanes initialized and alive — a dead lane no longer honors
    /// the pair's contract, so callers replace the pool wholesale rather
    /// than ride half of it.
    var connected: Bool { get async {
        let primaryUp = await primary.connected
        let readUp = await readConnection.connected
        return primaryUp && readUp
    } }

    /// The daemon socket both lanes are bound to.
    var boundSocket: String? { get async { await primary.boundSocket } }

    /// Mutations and reads — routes over `primary`. Same contract as
    /// `CuaConnection.call` (mutations never replay).
    func call(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> JSONValue {
        try await primary.call(name, arguments: arguments, timeout: timeout)
    }

    /// Reads — routes over `readConnection` so observations dispatch in
    /// real parallel with primary-lane mutations. Read-only calls are
    /// retry/ordering-safe (`CuaConnection.callResult` retries transient
    /// faults), so a stale answer here is always just a retry away.
    /// Non-read tools throw `.remote` before reaching the wire.
    func callRead(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> JSONValue {
        try await callReadResult(name, arguments: arguments, timeout: timeout).structured
    }

    /// Full-payload variant of `call` for callers that need the content
    /// blocks alongside structuredContent.
    func callResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> CuaToolResult {
        try await primary.callResult(name, arguments: arguments, timeout: timeout)
    }

    /// Full-payload variant of `callRead`.
    func callReadResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> CuaToolResult {
        guard CuaConnection.isReadOnly(name, arguments: arguments) else {
            throw DriverConnectionError.remote(
                "callRead only routes read-only tools — \(name) can mutate; use call(_:arguments:timeout:).")
        }
        return try await readConnection.callResult(name, arguments: arguments, timeout: timeout)
    }

    /// Show/hide the session's agent cursor — routes over `primary` (the
    /// tool is a mutation). Idempotent and fire-and-forget safe; callable
    /// at session start.
    func setAgentCursorEnabled(_ enabled: Bool, session: String) async {
        await primary.setAgentCursorEnabled(enabled, session: session)
    }

    /// Ends both lanes — one teardown, never half a pair.
    func close() async {
        await primary.close()
        await readConnection.close()
    }
}

extension CuaConnectionPool where Lane == CuaConnection {
    /// Resolves the shared daemon's socket and binds both lanes to it.
    func connect() async throws {
        try await connect(socket: CuaDaemonHost.shared.socket())
    }

    /// A standalone read-only lane for owners that keep their own primary
    /// connection (e.g. `VoiceTaskCoordinator.transport`): `connect(socket:)`
    /// it to the SAME daemon socket as the primary, then route calls that
    /// satisfy `CuaConnection.isReadOnly` through it. Teardown is
    /// caller-owned — close it alongside the primary; the sick-daemon hook
    /// is wired by `CuaConnection.init`'s default.
    static func makeReadConnection(
        onToolCall: (@Sendable (String, Int?) -> Void)? = nil
    ) -> CuaConnection {
        CuaConnection(onToolCall: onToolCall)
    }
}

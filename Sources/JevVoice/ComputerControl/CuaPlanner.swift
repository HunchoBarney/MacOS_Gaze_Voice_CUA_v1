import Foundation
import JevVoiceCore
import OSLog

/// What the planner hands back — advisory only. `steps` sketch the route;
/// `successContains` are literal strings that must be observable on screen
/// when the goal is truly done (they fold into DriveTask.successContains,
/// so they still gate on the observed corpus — a plan can never claim
/// success itself).
struct DrivePlan: Sendable, Equatable {
    struct Hints: Sendable, Equatable {
        var preferVisual = false
        var notes: String?
        init(preferVisual: Bool = false, notes: String? = nil) {
            self.preferVisual = preferVisual; self.notes = notes
        }
    }
    var steps: [String] = []
    var successContains: [String] = []
    var hints = Hints()
    init(steps: [String] = [], successContains: [String] = [], hints: Hints = Hints()) {
        self.steps = steps; self.successContains = successContains; self.hints = hints
    }
}

/// The planner seam — an injected stub (tests) or the vendored-codex
/// client. The contract is one optional plan; nil always means "run the
/// plain loop".
protocol CuaPlanning: Sendable {
    func plan(goal: String, appName: String?, windowTitle: String?,
              memoryContext: String?, previousContext: String?) async -> DrivePlan?
    /// Best-effort session prewarm fired when a drive task is queued — the
    /// spawn overlaps consent/lease wait so the real plan call lands warm.
    func warmUp() async
}

extension CuaPlanning {
    func warmUp() async {}
}

/// Warm, persistent planner over the vendored codex app-server: one
/// process, one ephemeral thread, one bounded turn per plan. Auth is the
/// user's own ChatGPT login — ~/.codex/auth.json seeded into an isolated
/// CODEX_HOME at spawn, the same pattern CodexRuntimeBridge uses for
/// agents. The thread runs `approval_policy = "never"` + read-only
/// sandbox: the planner plans, it can never dispatch.
/// Every failure — no binary, no auth, timeout, malformed JSON — returns
/// nil; this actor never throws.
actor CuaPlanner: CuaPlanning {
    static let shared = CuaPlanner()
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice",
                                    category: "cua-planner")

    private let binary: URL?
    private let codexHome: URL
    /// The login source dir (auth.json, config.toml) — real `~/.codex` in
    /// production, temp dir in tests.
    private let userHome: URL
    private let turnTimeout: TimeInterval
    private var client: CodexProtocolClient?
    private var threadID: String?
    /// Cold starts are shared — two plan calls racing the first spawn join
    /// one bootstrap instead of binding twins to the same CODEX_HOME. The
    /// token lets the spawn task clear it exactly when IT finishes: an
    /// awaiting caller cancelled by the 4s plan budget must not clear the
    /// shared handle and trigger a parallel spawn.
    private var starting: (token: UUID,
                           task: Task<(client: CodexProtocolClient, threadID: String), Error>)?

    init(codexBinary: URL? = nil, codexHome: URL? = nil, userHome: URL? = nil,
         turnTimeout: TimeInterval = 15) {
        self.binary = codexBinary ?? Self.defaultBinary()
        self.codexHome = codexHome ?? Self.defaultCodexHome()
        self.userHome = userHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.turnTimeout = turnTimeout
    }

    /// Bundle first, dev fallback — the same resolution main.swift uses for
    /// the agents runtime. `bin/codex` covers the vendored npm layout where
    /// the launcher sits one level deeper.
    private static func defaultBinary() -> URL? {
        let bundled = [
            Bundle.main.resourceURL?.appendingPathComponent("CodexRuntime/codex"),
            Bundle.main.resourceURL?.appendingPathComponent("CodexRuntime/bin/codex")
        ].compactMap { $0 }
        let dev = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex")
        return (bundled + [dev]).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func defaultCodexHome() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice/Planner/codex-home", isDirectory: true)
    }

    /// `model = "…"` from the user's own ~/.codex/config.toml — the planner
    /// inherits whichever model the account is tuned to. Nil → codex default.
    private static func userCodexModel(userHome: URL) -> String? {
        guard let text = try? String(contentsOf: userHome.appendingPathComponent("config.toml"),
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("model"), trimmed.contains("=") else { continue }
            let value = trimmed.split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !unquoted.isEmpty { return unquoted }
        }
        return nil
    }

    private static func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Bind the session ahead of the first plan call. Shielded from caller
    /// cancellation — a cancelled await must not strand the half-spawned
    /// process, so the spawn task stores its own result on completion.
    func warmUp() async {
        _ = try? await ensureSession()
    }

    /// Lazily spawn + thread-bind once; a dead client is replaced wholesale
    /// rather than revived (the protocol client's events die with it).
    private func ensureSession() async throws -> (client: CodexProtocolClient, threadID: String) {
        if let client, let threadID, await client.connected { return (client, threadID) }
        if let starting { return try await starting.task.value }
        let binary = self.binary, codexHome = self.codexHome, userHome = self.userHome
        let token = UUID()
        // Unstructured so caller cancellation can't kill the spawn: the
        // task adopts its own result, so a cancelled-away cold call still
        // leaves a warm session for the next task.
        let task = Task<(client: CodexProtocolClient, threadID: String), Error> {
            do {
                let session = try await Self.spawn(binary: binary, codexHome: codexHome,
                                                   userHome: userHome)
                self.adoptSession(session, token: token)
                return session
            } catch {
                self.failStart(token: token)
                throw error
            }
        }
        starting = (token, task)
        return try await task.value
    }

    private func adoptSession(_ session: (client: CodexProtocolClient, threadID: String),
                              token: UUID) {
        if starting?.token == token { starting = nil }
        if let old = client { Task { await old.close() } }
        client = session.client
        threadID = session.threadID
    }

    private func failStart(token: UUID) {
        if starting?.token == token { starting = nil }
    }

    /// Spawn an app-server with an isolated CODEX_HOME: config.toml pins
    /// never-approve + read-only, and a fresh copy of the user's auth.json
    /// rides in so a token refresh here can't strand the user's own
    /// install. ChatGPT login only — no auth.json, no planner.
    private static func spawn(binary: URL?, codexHome: URL,
                              userHome: URL) async throws -> (client: CodexProtocolClient,
                                                              threadID: String) {
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CodexConnectionError.unavailable
        }
        let fileManager = FileManager.default
        let userAuth = userHome.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: userAuth.path) else {
            throw CodexConnectionError.unavailable
        }
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        var toml = "approval_policy = \"never\"\nsandbox_mode = \"read-only\"\n"
        let model = userCodexModel(userHome: userHome)
        if let model { toml = "model = \"\(tomlEscape(model))\"\n" + toml }
        try toml.write(to: codexHome.appendingPathComponent("config.toml"),
                       atomically: true, encoding: .utf8)
        let authDest = codexHome.appendingPathComponent("auth.json")
        try? fileManager.removeItem(at: authDest)
        try? fileManager.copyItem(at: userAuth, to: authDest)
        let client = CodexProtocolClient(executable: binary,
                                       environment: ["CODEX_HOME": codexHome.path],
                                       clientName: "JevVoice-Planner", clientVersion: "1")
        try await client.start()
        let threadID = try await client.startThread(cwd: codexHome.path, model: model,
                                                    developerInstructions: systemPrompt,
                                                    ephemeral: true)
        return (client, threadID)
    }

    /// The standing planner persona rides the thread's developerInstructions
    /// so each turn stays a small payload.
    private static let systemPrompt = """
    You plan voice-driven macOS GUI tasks. An executor loop that can click \
    elements, pixel-click, type, press keys and scroll runs your plan — you \
    never act and never see the screen.
    Reply with ONLY a JSON object, no prose and no markdown fences:
    {"steps":["short ordered step strings"],"success_contains":["literal strings that must be visible on screen when the goal is truly done"],"prefer_visual":true|false,"notes":"optional one-line hint"}
    2-8 grounded steps. success_contains is observed-evidence text, never a \
    restatement of the request. prefer_visual only when the surface is \
    pixel-drawn (terminals, canvas apps, remote desktops).
    """

    /// One bounded turn payload — kept small: goal, target, memory, context.
    private static func prompt(goal: String, appName: String?, windowTitle: String?,
                               memoryContext: String?, previousContext: String?) -> String {
        """
        Plan this task.
        Goal: \(goal)
        App: \(appName ?? "unspecified")
        Window: \(windowTitle ?? "-")
        Memory: \(memoryContext ?? "none")
        Context: \(previousContext ?? "none")
        """
    }

    /// One bounded turn against the warm session → a plan, or nil on any
    /// failure. Never throws.
    func plan(goal: String, appName: String?, windowTitle: String?,
              memoryContext: String?, previousContext: String?) async -> DrivePlan? {
        let session: (client: CodexProtocolClient, threadID: String)
        do {
            session = try await ensureSession()
        } catch {
            Self.log.notice("planner_session_failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            let turnID = try await session.client.startTurn(
                threadID: session.threadID,
                text: Self.prompt(goal: goal, appName: appName, windowTitle: windowTitle,
                                  memoryContext: memoryContext,
                                  previousContext: previousContext))
            guard let text = await Self.collectReply(client: session.client,
                                                     threadID: session.threadID,
                                                     turnID: turnID,
                                                     timeout: turnTimeout) else {
                Self.log.notice("planner_turn_no_reply")
                return nil
            }
            let plan = Self.parse(text)
            if plan == nil {
                Self.log.notice("planner_malformed_reply \(String(text.prefix(120)), privacy: .public)")
            }
            return plan
        } catch {
            Self.log.notice("planner_turn_failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Drain the turn's agent message until `turn/completed` or the
    /// timeout; on timeout the turn is interrupted best-effort so the warm
    /// session doesn't carry a zombie turn into the next plan. Caller
    /// cancellation lands the same way — the sleep throws, the interrupt
    /// still fires.
    private static func collectReply(client: CodexProtocolClient, threadID: String,
                                     turnID: String, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                for await event in client.events {
                    switch event {
                    case .agentMessageDelta(let tid, let tID, _, let delta)
                        where tid == threadID && tID == turnID:
                        text += delta
                    case .itemCompleted(let tid, let tID, let item)
                        where tid == threadID && tID == turnID:
                        // The completed agent message carries the whole text —
                        // prefer it over the accumulated deltas.
                        if item["type"]?.string == "agentMessage",
                           let full = item["text"]?.string, !full.isEmpty {
                            text = full
                        }
                    case .turnCompleted(let tid, let turn)
                        where tid == threadID && turn.id == turnID:
                        return text
                    case .error(_, _, _, let tID) where tID == turnID:
                        return text.isEmpty ? nil : text
                    default:
                        continue
                    }
                }
                return text.isEmpty ? nil : text
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                try? await client.interruptTurn(threadID: threadID, turnID: turnID)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first?.isEmpty == false ? first : nil
        }
    }

    /// Defensive JSON extraction: the model is instructed to emit only JSON
    /// but prose happens — take the outermost {…} span, decode loosely, and
    /// refuse a plan with neither steps nor success strings.
    static func parse(_ text: String) -> DrivePlan? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"), open <= close else { return nil }
        guard let object = try? JSONSerialization.jsonObject(
                with: Data(text[open...close].utf8)) as? [String: Any] else { return nil }
        func strings(_ keys: [String]) -> [String] {
            for key in keys {
                if let list = object[key] as? [Any] {
                    let values = list.compactMap {
                        ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }
                    if !values.isEmpty { return values }
                } else if let single = (object[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !single.isEmpty {
                    return [single]
                }
            }
            return []
        }
        let hintsObject = object["hints"] as? [String: Any]
        let preferVisual = (object["prefer_visual"] ?? object["preferVisual"]
            ?? hintsObject?["prefer_visual"] ?? hintsObject?["preferVisual"]) as? Bool ?? false
        let notes = ((object["notes"] ?? hintsObject?["notes"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = strings(["steps", "plan"]).prefix(8)
        let success = strings(["success_contains", "successContains", "success"]).prefix(6)
        guard !steps.isEmpty || !success.isEmpty else { return nil }
        return DrivePlan(steps: steps.map { String($0.prefix(120)) },
                         successContains: success.map { String($0.prefix(120)) },
                         hints: .init(preferVisual: preferVisual,
                                      notes: notes?.isEmpty == false ? notes : nil))
    }

    /// Drop the warm session — the next plan respawns on demand.
    func close() {
        starting?.task.cancel()
        starting = nil
        if let client {
            self.client = nil
            threadID = nil
            Task { await client.close() }
        }
    }
}

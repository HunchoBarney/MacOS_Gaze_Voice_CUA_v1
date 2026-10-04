import Foundation
import JevVoiceCore

// MARK: - Mini-Clicky shared contracts
//
// Wave-0 foundation of the subagent build. Every lane codes against these
// types — a lane that needs a different shape changes THIS file (coordinator
// approval) rather than inventing its own. Reference: Clicky mirror docs
// `Clicky_Decompile/mirror/06-computer-use.md` (drive_until, consent gate,
// jev-use) and `mirror/05-agent-runtime.md` (agents, routines, workspaces).

// MARK: Drive-loop contract (Clicky `drive_until` / `suggest_action`)

/// What Jev decides at each step while driving a window. Jev picks an
/// element + kind — it NEVER writes text. Caller-supplied literal text lives
/// in `DriveTask.values`, keyed by field label.
public struct StepJudgment: Sendable, Equatable {
    public enum Kind: String, Sendable { case press, type, scroll, none }
    /// Token identifying the chosen element in the loop's projected
    /// interactive-element list (nil when `kind == .none` or `done`).
    public var elementToken: String?
    public var kind: Kind
    public var confidence: Double
    /// Model claims the goal is satisfied by observed state.
    public var done: Bool
    /// Model reports it cannot progress (reason for the user).
    public var blocked: String?
    /// Field-label tokens the model wants filled on a `type` step.
    public var fillTokens: [String]
    public init(elementToken: String? = nil, kind: Kind, confidence: Double,
                done: Bool = false, blocked: String? = nil, fillTokens: [String] = []) {
        self.elementToken = elementToken; self.kind = kind
        self.confidence = confidence; self.done = done
        self.blocked = blocked; self.fillTokens = fillTokens
    }
}

/// Terminal status of a `driveUntil` run — mirrors Clicky's jev-use statuses.
public enum DriveStatus: Sendable, Equatable {
    case done
    case handedBack(HandBackReason)
    case blocked(String)
    /// Loop found fields needing text the caller didn't supply in `values`.
    case needsText(fieldLabel: String)
    /// An input tool was refused by the consent gate this turn.
    case blockedByConsent(String)
    case maxSteps(history: [String])
    case cancelled

    public enum HandBackReason: String, Sendable {
        /// confidence < 0.5 — guessing; hand to the planner/LLM.
        case lowConfidence = "low_confidence"
        case noCandidate = "no_candidate"
        /// AX tree empty/inert → caller should escalate to pixel/screenshot.
        case noInteractiveElements = "no_interactive_elements"
        case untrustedAnswer = "untrusted_answer"
    }
}

/// The task handed to the drive loop — mirrors Clicky's `drive_until` args.
public struct DriveTask: Sendable {
    public var goal: String
    /// Bundle id preferred, app name accepted.
    public var application: String?
    public var pid: Int?
    public var windowID: Int?
    /// Field-label → literal text supplied BY THE CALLER. Jev selects fields;
    /// it never generates text.
    public var values: [String: String]
    /// Element labels Jev may never press — enforced in code, twice:
    /// excluded from offered candidates AND re-checked on the model's answer.
    public var deny: [String]
    /// Postcondition strings the verifier looks for after effects.
    public var successContains: [String]
    public var maxSteps: Int
    public init(goal: String, application: String? = nil, pid: Int? = nil,
                windowID: Int? = nil, values: [String: String] = [:],
                deny: [String] = [], successContains: [String] = [], maxSteps: Int = 24) {
        self.goal = goal; self.application = application
        self.pid = pid; self.windowID = windowID; self.values = values
        self.deny = deny; self.successContains = successContains
        self.maxSteps = maxSteps
    }
}

/// Result envelope returned by `driveUntil` (loop + jev-use MCP tool).
public struct DriveResult: Sendable {
    public var status: DriveStatus
    /// Human-readable step ledger — mirrors Clicky's `history` return.
    public var history: [String]
    public var pid: Int?
    public var windowID: Int?
    public init(status: DriveStatus, history: [String] = [], pid: Int? = nil, windowID: Int? = nil) {
        self.status = status; self.history = history; self.pid = pid; self.windowID = windowID
    }
}

// MARK: Planner contract (CompanionBrain output)

/// One structured decision per utterance — the replacement for the
/// 19-question `decide()` battery. CompanionBrain returns exactly one.
public enum PlannerDecision: Sendable {
    /// A task spec ready for the drive loop.
    case execute(TaskSpec)
    /// Ask the user a single question (spoken + card).
    case clarify(ClarifyRequest)
    /// Answer aloud/in the card — no computer action.
    case answer(text: String)
    /// The next step needs input consent this turn.
    case consentNeeded(ConsentRequest)
    case refuse(reason: String)
    /// Delegate work to a persistent agent (Wave 2+).
    case delegate(DelegationRequest)
    /// Follow-up message into an existing agent's thread.
    case sendToAgent(slug: String, message: String)
    /// Read an agent's findings without waking it.
    case agentMemory(slug: String)
}

/// App-level task description produced by the planner (pre-resolution).
/// `CuaVoiceRuntime` resolves app/window to `DriveTask` for the loop.
public struct TaskSpec: Sendable {
    public enum Scope: String, Sendable { case open, create, work }
    public var goal: String
    public var application: String?
    public var scope: Scope
    /// Window title/name when the user or planner names one.
    public var window: String?
    public var deny: [String]
    public var values: [String: String]
    /// Literal text the user dictated for insertion (planner-parsed).
    public var literalText: String?
    public var successContains: [String]
    public init(goal: String, application: String? = nil, scope: Scope = .work,
                window: String? = nil, deny: [String] = [], values: [String: String] = [:],
                literalText: String? = nil, successContains: [String] = []) {
        self.goal = goal; self.application = application; self.scope = scope
        self.window = window; self.deny = deny; self.values = values
        self.literalText = literalText; self.successContains = successContains
    }
}

public struct ClarifyRequest: Sendable {
    public var question: String
    public var options: [String]
    public init(question: String, options: [String] = []) {
        self.question = question; self.options = options
    }
}

/// Delegate work to a persistent agent — mirrors Clicky's `sessions_spawn`.
public struct DelegationRequest: Sendable {
    /// Slug of an existing agent, or nil to found a new one.
    public var agentSlug: String?
    /// Founding fields when `agentSlug == nil` (LLM-proposed, Clicky lite).
    public var newAgentName: String?
    public var newAgentRole: String?
    public var newAgentDescription: String?
    /// The task/message handed to the agent.
    public var message: String
    public init(agentSlug: String? = nil, newAgentName: String? = nil,
                newAgentRole: String? = nil, newAgentDescription: String? = nil,
                message: String) {
        self.agentSlug = agentSlug; self.newAgentName = newAgentName
        self.newAgentRole = newAgentRole; self.newAgentDescription = newAgentDescription
        self.message = message
    }
}

/// Context the planner sees — deliberately small (Clicky keeps planner
/// context lean; the loop handles step-level detail).
public struct PlannerContext: Sendable {
    /// Recent user intents/tasks for follow-up routing ("it", "again").
    public var recentIntents: [String]
    /// Pending clarification an utterance might answer.
    public var pendingClarify: ClarifyRequest?
    /// Pending agent/consent ask a bare "yes"/"no" resolves.
    public var pendingConsent: ConsentRequest?
    /// Agent roster summary for delegation routing.
    public var agents: [CompanionAgent]
    /// Short foreground-app hint ("TextEdit — Untitled 3").
    public var foregroundHint: String?
    public init(recentIntents: [String] = [], pendingClarify: ClarifyRequest? = nil,
                pendingConsent: ConsentRequest? = nil, agents: [CompanionAgent] = [],
                foregroundHint: String? = nil) {
        self.recentIntents = recentIntents; self.pendingClarify = pendingClarify
        self.pendingConsent = pendingConsent; self.agents = agents
        self.foregroundHint = foregroundHint
    }
}

/// The seam every planner implementation satisfies.
public protocol CompanionPlanning: Sendable {
    func decide(utterance: String, context: PlannerContext) async throws -> PlannerDecision
}

// MARK: Agent contract (persistent named agents — Clicky's "Clickys")

/// A persistent agent: vendored Codex thread + workspace + memory + routines.
public struct CompanionAgent: Codable, Sendable, Identifiable, Equatable {
    /// Filesystem/agent slug, e.g. "inbox-desk". Stable identity.
    public var slug: String
    public var name: String
    /// What the agent is for ("triage and summarize my email").
    public var role: String
    public var agentDescription: String
    /// ~/Library/Application Support/JevVoice/Agents/<slug>/
    public var workspacePath: String
    /// Isolated CODEX_HOME under the workspace.
    public var codexHomePath: String
    /// Codex thread ids, most recent last.
    public var threadIDs: [String]
    public var routines: [Routine]
    public var createdAt: Date
    public var id: String { slug }
    public init(slug: String, name: String, role: String, description: String,
                workspacePath: String, codexHomePath: String,
                threadIDs: [String] = [], routines: [Routine] = [], createdAt: Date = Date()) {
        self.slug = slug; self.name = name; self.role = role
        self.agentDescription = description; self.workspacePath = workspacePath
        self.codexHomePath = codexHomePath; self.threadIDs = threadIDs
        self.routines = routines; self.createdAt = createdAt
    }
}

/// Scheduled re-run of a task inside the agent's thread (Clicky routine).
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var everyMinutes: Int
    public var task: String
    public var enabled: Bool
    public init(id: String = UUID().uuidString, everyMinutes: Int, task: String, enabled: Bool = true) {
        self.id = id; self.everyMinutes = everyMinutes; self.task = task; self.enabled = enabled
    }
}

// MARK: Consent gate (computer-use shim + voice path share this)

/// A pending or resolved consent ask. Keyed per (agent, turn) — approving
/// one agent never arms another.
public struct ConsentRequest: Codable, Sendable, Identifiable {
    public var id: String
    /// Nil for the voice-companion's own direct path.
    public var agentSlug: String?
    /// The turn the gate arms; nil = voice single-shot task.
    public var turnID: String?
    /// Natural-language ask shown + spoken ("Inbox Desk wants to click and
    /// type in Mail to send the reply").
    public var summary: String
    public var reason: String
    public var state: State
    public enum State: String, Codable, Sendable { case pending, approved, denied }
    public init(id: String = UUID().uuidString, agentSlug: String? = nil,
                turnID: String? = nil, summary: String, reason: String,
                state: State = .pending) {
        self.id = id; self.agentSlug = agentSlug; self.turnID = turnID
        self.summary = summary; self.reason = reason; self.state = state
    }
}

/// The gate the computer-use MCP shim and the voice path both consult.
/// Input tools are refused until the requesting (agent, turn) is approved;
/// observation tools are always permitted.
public protocol ConsentGating: Sendable {
    /// Throws `GateError.blockedByConsent` when input isn't permitted.
    func assertPermitted(tool: String, agentSlug: String?, turnID: String?) throws
    func approve(_ request: ConsentRequest)
    func deny(_ request: ConsentRequest)
    /// Currently-pending asks (bare voice "yes" resolves the sole pending one).
    func pending() -> [ConsentRequest]
}

public enum GateError: Error, Sendable, Equatable {
    case blockedByConsent(summary: String)
}

/// Consent contract for the computer-use shim (Clicky parity): observation
/// tools are always open; EVERYTHING else is consent-gated. Fail-closed by
/// construction — a new/unknown driver tool gates rather than leaks open.
/// Tool list verified against the pinned driver's mcp-tools.mdx (0.32.0).
public enum ConsentContract {
    /// Driver tools permitted without consent (observation only).
    public static let observationTools: Set<String> = [
        "list_apps", "list_windows", "get_window_state",
        "get_accessibility_tree", "get_desktop_state", "get_screen_size",
        "get_cursor_position", "get_config", "get_recording_state",
        "get_agent_cursor_state", "check_permissions", "health_report",
        "check_for_update", "clipboard_read", "get_browser_state",
        "get_session", "list_sessions", "get_session_state",
        "parse_visual_regions", "verify_state",
    ]
    /// Anything not an observation tool is consent-gated input/action —
    /// launch_app, kill_app, click*, type_*, press_key, hotkey, set_value,
    /// scroll, drag, move_cursor, zoom, bring_to_front, set_window_frame,
    /// browser_*, clipboard_write, page, recording/session/config mutators,
    /// install_*, invoke_menu, escalate_session — including future tools.
    public static func requiresConsent(_ tool: String) -> Bool {
        !observationTools.contains(tool)
    }
    /// `delivery_mode` value required on every forwarded input call.
    public static let requiredDeliveryMode = "background"
    /// Detects desktop-scope requests in BOTH arg shapes: top-level
    /// `scope:"desktop"` and the driver's preferred nested
    /// `target:{kind:"desktop",…}` targeting object. Raw desktop-coordinate
    /// control is always refused (no pointer hijack).
    public static func requestsDesktopScope(_ args: JSONValue) -> Bool {
        if args["scope"]?.string == "desktop" { return true }
        return containsDesktopTarget(args)
    }
    private static func containsDesktopTarget(_ value: JSONValue) -> Bool {
        switch value {
        case let .object(dict):
            if dict["kind"]?.string == "desktop" { return true }
            return dict.values.contains(where: containsDesktopTarget)
        case let .array(items):
            return items.contains(where: containsDesktopTarget)
        default:
            return false
        }
    }
}

// MARK: Agent cursor identity

/// Visual identity for an agent's overlay cursor — observability, never
/// pointer hijack. NOTE: today the driver draws the agent cursor
/// (`agentCursorEnabled`); per-agent identity needs either driver label
/// support or our own overlay — implementation detail left to the lane.
public struct AgentCursor: Sendable, Equatable {
    public var agentSlug: String?   // nil = voice direct path
    public var label: String        // e.g. "Inbox Desk"
    public var colorHex: String     // e.g. "#14b8a6"
    public init(agentSlug: String? = nil, label: String, colorHex: String) {
        self.agentSlug = agentSlug; self.label = label; self.colorHex = colorHex
    }
    /// Deterministic palette so each agent keeps a stable color.
    public static func palette(for slug: String?) -> String {
        let colors = ["#14b8a6", "#f59e0b", "#8b5cf6", "#ec4899", "#22c55e", "#3b82f6"]
        guard let slug else { return "#14b8a6" }
        return colors[abs(slug.hashValue) % colors.count]
    }
}

// MARK: jev-use MCP tools (agent-facing surface)

/// Tool names the in-app jev-use MCP server exposes to agents.
public enum JevUseTools {
    public static let driveUntil = "drive_until"
    public static let suggestAction = "suggest_action"
}

// MARK: Speech output + dictation seams

/// TTS seam — every spoken surface goes through this.
public protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String)
    func stop()
}

/// Dictation delivery seam — Fn+Ctrl path delivers literal text to the
/// focused field; never passes through the planner.
public protocol DictationDelivering: Sendable {
    func deliver(_ text: String) async throws
}

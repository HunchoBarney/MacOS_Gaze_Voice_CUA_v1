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
    /// Settled only when at least one effect dispatched this run AND the
    /// postcondition was verified — "done" is an effect, never a claim.
    case done
    /// The goal was already true on screen — zero effects dispatched and
    /// none needed. Distinct from `done` so callers speak it differently
    /// and never fabricate "I did it" from pure observation.
    case alreadySatisfied(reason: String)
    case handedBack(HandBackReason)
    case blocked(String)
    /// Loop found fields needing text the caller didn't supply in `values`.
    case needsText(fieldLabel: String)
    /// The named window resolves to several live candidates — the caller
    /// asks the user which one and resumes with `windowName` disambiguated.
    case needsWindow(candidates: [String])
    /// An input tool was refused by the consent gate this turn.
    case blockedByConsent(String)
    case maxSteps(history: [String])
    case cancelled

    public enum HandBackReason: Sendable, Equatable {
        /// confidence < 0.5 — guessing; hand to the planner/LLM.
        case lowConfidence
        /// Kept for parity with the Clicky vocabulary — the loop resolves
        /// "no pick" as untrustedAnswer today rather than producing this.
        case noCandidate
        /// AX tree empty/inert → caller should escalate to pixel/screenshot.
        case noInteractiveElements
        case untrustedAnswer
        /// The judge could not pick confidently — the caller asks the user
        /// to choose among these candidate action descriptions.
        case needsChoice(options: [String])

        /// Stable wire string — consumers (JevUseMCPServer) key on it.
        public var rawValue: String {
            switch self {
            case .lowConfidence: return "low_confidence"
            case .noCandidate: return "no_candidate"
            case .noInteractiveElements: return "no_interactive_elements"
            case .untrustedAnswer: return "untrusted_answer"
            case .needsChoice: return "needs_choice"
            }
        }
    }
}

/// The task handed to the drive loop — mirrors Clicky's `drive_until` args.
public struct DriveTask: Sendable {
    public var goal: String
    /// Bundle id preferred, app name accepted.
    public var application: String?
    public var pid: Int?
    public var windowID: Int?
    /// The window the request names — matched case-insensitively against
    /// titles; several matches hand the choice back as a question.
    public var windowName: String?
    /// The user's answer to a question this intent asked — carried into
    /// `previous_context` on every judgment so a re-asked ambiguity can be
    /// resolved by the reply instead of looping identically.
    public var previousContext: String?
    /// Honest task scope — `.open` is satisfied by the app running.
    public var scope: TaskSpec.Scope
    /// Field-label → literal text supplied BY THE CALLER. Jev selects fields;
    /// it never generates text.
    public var values: [String: String]
    /// Element labels Jev may never press — enforced in code, twice:
    /// excluded from offered candidates AND re-checked on the model's answer.
    public var deny: [String]
    /// Postcondition strings the verifier looks for after effects.
    public var successContains: [String]
    /// The caller asked the app to come forward — the bound window is
    /// raised once at drive start. Element-scoped and explicitly
    /// background work leaves this false so the user's front app survives.
    public var foreground: Bool
    public var maxSteps: Int
    public init(goal: String, application: String? = nil, pid: Int? = nil,
                windowID: Int? = nil, windowName: String? = nil,
                previousContext: String? = nil,
                scope: TaskSpec.Scope = .work, values: [String: String] = [:],
                deny: [String] = [], successContains: [String] = [],
                foreground: Bool = false, maxSteps: Int = 24) {
        self.goal = goal; self.application = application
        self.pid = pid; self.windowID = windowID; self.windowName = windowName
        self.previousContext = previousContext
        self.scope = scope; self.values = values
        self.deny = deny; self.successContains = successContains
        self.foreground = foreground
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
    /// The bundle id the loop actually resolved — observed identity, never
    /// the caller's application spelling.
    public var bundleID: String?
    /// At least one effect dispatched and was confirmed this run — the
    /// only honest base for `.done`. Callers must gate "Done" speech on
    /// this; `.alreadySatisfied` carries it false by definition.
    public var dispatchedEffect: Bool
    /// Why the loop settled blocked — the judge's own reason when it gave
    /// one, so callers speak "couldn't find 'Yanky'" instead of "(other)".
    public var blockedReason: String?
    public init(status: DriveStatus, history: [String] = [], pid: Int? = nil, windowID: Int? = nil,
                bundleID: String? = nil, dispatchedEffect: Bool = false,
                blockedReason: String? = nil) {
        self.status = status; self.history = history; self.pid = pid
        self.windowID = windowID; self.bundleID = bundleID
        self.dispatchedEffect = dispatchedEffect; self.blockedReason = blockedReason
    }
}

// MARK: Voice task contract

/// App-level task description built from the realtime `computer_command`
/// tool call. `CuaVoiceRuntime` resolves app/window to `DriveTask` for the loop.
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
    /// Literal text the user dictated for insertion (`literal_text` tool arg).
    public var literalText: String?
    public var successContains: [String]
    /// True when the request asks the app to come forward — "open X",
    /// "show X", an explicit "in the foreground". Dictate-into-window and
    /// background phrasing leave it false so the user's foreground app is
    /// preserved.
    public var foreground: Bool
    /// Ordered steps the voice model emitted with `computer_command` — the
    /// inline plan for multi-part instructions ("open Mail then reply to
    /// mom" → ["open Mail", "reply to mom"]). Empty for a single action.
    /// Advisory: folds into the loop's previousContext, never claims done.
    public var steps: [String]
    public init(goal: String, application: String? = nil, scope: Scope = .work,
                window: String? = nil, deny: [String] = [], values: [String: String] = [:],
                literalText: String? = nil, successContains: [String] = [],
                foreground: Bool = false, steps: [String] = []) {
        self.goal = goal; self.application = application; self.scope = scope
        self.window = window; self.deny = deny; self.values = values
        self.literalText = literalText; self.successContains = successContains
        self.foreground = foreground; self.steps = steps
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
        if args["scope"]?.string?.lowercased() == "desktop" { return true }
        return containsDesktopTarget(args)
    }
    private static func containsDesktopTarget(_ value: JSONValue) -> Bool {
        switch value {
        case let .object(dict):
            if dict["kind"]?.string?.lowercased() == "desktop" { return true }
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

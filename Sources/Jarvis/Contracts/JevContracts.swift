import Foundation
import JarvisCore

// MARK: - Shared contracts
//
// Every lane codes against these types — a lane that needs a different
// shape changes THIS file rather than inventing its own. The drive loop
// (`Drive/DriveLoop.swift`) owns step selection internally; what crosses
// its boundary is `DriveTask` in, `DriveResult` out.

// MARK: Drive-loop contract

/// Terminal status of a `driveUntil` run.
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

    /// Why a consent gate stopped the task — the agent-facing
    /// `describe()` keys on this classification, never on reason-string
    /// sniffing.
    public enum ConsentBlock: Sendable, Equatable {
        /// A protected-list hit, a denied tool, or the task's own deny
        /// rule — no grant or approval reverses it.
        case permanent
        /// The standing grant is absent and no ask channel ran — the
        /// one block the settings toggle actually fixes.
        case missingGrant
        /// A live confirm card ran and the user declined this action.
        case declined
    }

    public enum HandBackReason: Sendable, Equatable {
        /// confidence < 0.5 — guessing; hand to the planner/LLM.
        case lowConfidence
        /// Kept in the vocabulary — the loop resolves
        /// "no pick" as untrustedAnswer today rather than producing this.
        case noCandidate
        /// AX tree empty/inert → caller should escalate to pixel/screenshot.
        case noInteractiveElements
        case untrustedAnswer
        /// The judge could not pick confidently — the caller asks the user
        /// to choose among these candidate action descriptions.
        case needsChoice(options: [String])

        /// Stable wire string — the MCP server keys on it.
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

/// The task handed to the drive loop — the `drive_until` arguments.
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
    /// Element labels Jev may never press — enforced at dispatch: every
    /// effect (and the window-control shortcut) runs the label through the
    /// policy gate with this list, and a deny match aborts the task. They
    /// are NOT filtered out of the candidates offered to the model.
    public var deny: [String]
    /// Postcondition strings the verifier looks for after effects.
    public var successContains: [String]
    /// The caller asked the app to come forward — the bound window is
    /// raised once at drive start. Element-scoped and explicitly
    /// background work leaves this false so the user's front app survives.
    public var foreground: Bool
    public init(goal: String, application: String? = nil, pid: Int? = nil,
                windowID: Int? = nil, windowName: String? = nil,
                previousContext: String? = nil,
                scope: TaskSpec.Scope = .work, values: [String: String] = [:],
                deny: [String] = [], successContains: [String] = [],
                foreground: Bool = false) {
        self.goal = goal; self.application = application
        self.pid = pid; self.windowID = windowID; self.windowName = windowName
        self.previousContext = previousContext
        self.scope = scope; self.values = values
        self.deny = deny; self.successContains = successContains
        self.foreground = foreground
    }
}

/// Result envelope returned by `driveUntil` (loop + jev-use MCP tool).
public struct DriveResult: Sendable {
    public var status: DriveStatus
    /// Human-readable step ledger — the `history` return.
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
    /// Which consent refusal ended a `.blockedByConsent` run — set by the
    /// loop's policy gate, read by `describe` so the remedy it reports is
    /// honest for that refusal class.
    public var consentBlock: DriveStatus.ConsentBlock?
    public init(status: DriveStatus, history: [String] = [], pid: Int? = nil, windowID: Int? = nil,
                bundleID: String? = nil, dispatchedEffect: Bool = false,
                blockedReason: String? = nil,
                consentBlock: DriveStatus.ConsentBlock? = nil) {
        self.status = status; self.history = history; self.pid = pid
        self.windowID = windowID; self.bundleID = bundleID
        self.dispatchedEffect = dispatchedEffect; self.blockedReason = blockedReason
        self.consentBlock = consentBlock
    }
}

// MARK: Voice task contract

/// App-level task description built from the realtime `computer_command`
/// tool call. `VoiceTaskCoordinator` resolves it to `DriveTask`.
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

/// Delegate work to a persistent agent (`sessions_spawn`).
public struct DelegationRequest: Sendable {
    /// Slug of an existing agent, or nil to found a new one.
    public var agentSlug: String?
    /// Founding fields when `agentSlug == nil` (LLM-proposed).
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

// MARK: Agent contract (persistent named agents)

/// A persistent agent: vendored Codex thread + workspace + memory + routines.
public struct CompanionAgent: Codable, Sendable, Identifiable, Equatable {
    /// Filesystem/agent slug, e.g. "inbox-desk". Stable identity.
    public var slug: String
    public var name: String
    /// What the agent is for ("triage and summarize my email").
    public var role: String
    public var agentDescription: String
    /// ~/Library/Application Support/Jarvis/Agents/<slug>/
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

/// Scheduled re-run of a task inside the agent's thread.
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var everyMinutes: Int
    public var task: String
    public var enabled: Bool
    public init(id: String = UUID().uuidString, everyMinutes: Int, task: String, enabled: Bool = true) {
        self.id = id; self.everyMinutes = everyMinutes; self.task = task; self.enabled = enabled
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
    /// Deterministic palette so each agent keeps a stable color — FNV-1a
    /// over the slug's UTF-8. `hashValue` is process-randomized (colors
    /// reshuffled every launch) and `abs(Int.min)` traps; unsigned
    /// arithmetic avoids both.
    public static func palette(for slug: String?) -> String {
        let colors = ["#14b8a6", "#f59e0b", "#8b5cf6", "#ec4899", "#22c55e", "#3b82f6"]
        guard let slug else { return "#14b8a6" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in slug.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

// MARK: Speech output + dictation seams

/// TTS seam — every spoken surface goes through this.
public protocol SpeechSynthesizing: Sendable {
    func speak(_ text: String)
    func stop()
}

/// Dictation delivery seam — the dictation path delivers literal text to the
/// focused field; never passes through the planner.
public protocol DictationDelivering: Sendable {
    func deliver(_ text: String) async throws
}


import Foundation
import JevVoiceCore

/// The voice path's agent-facing seam. The Codex runtime lane wires a real
/// implementation; until then every delegation decision surfaces an honest
/// "not wired" answer instead of silently doing nothing.
protocol AgentBridging: Sendable {
    /// Slugs/names/roles the planner may route to.
    func roster() async -> [CompanionAgent]
    /// `delegate` decision: found or reuse a persistent agent. Returns the
    /// user-facing line the runtime reports.
    func delegate(_ request: DelegationRequest) async throws -> String
    /// `sendToAgent` decision: a follow-up into an existing agent's thread.
    func sendToAgent(slug: String, message: String) async throws -> String
    /// `agentMemory` decision: read findings without waking the agent.
    func agentMemory(slug: String) async throws -> String
}

/// CompanionBrain — the Clicky split's planner half. Exactly one provider
/// call per utterance yields exactly one `PlannerDecision`; Jev (through
/// `CuaAgentLoop.drive`) remains the per-step selector for computer work.
/// The model only ever *describes* work: literal insert text is the user's
/// own words carried through `TaskSpec.literalText`, never generated here.
struct CompanionBrain: CompanionPlanning {
    enum Failure: Error, LocalizedError {
        /// The provider answered but its payload is not a usable decision —
        /// surfaced to the caller so it can refuse honestly rather than
        /// guess at an action.
        case malformedDecision
        var errorDescription: String? {
            switch self {
            case .malformedDecision:
                return "The planner returned a response that is not a usable decision. Nothing was dispatched."
            }
        }
    }

    private let loadClient: @Sendable () async throws -> TextGenerationClient
    private let timeout: TimeInterval

    /// Injection seam: tests (and any alternate provider wiring) supply the
    /// client loader — a localhost endpoint needs no key, a throwing loader
    /// exercises the missing-key degrade path.
    init(loadClient: @escaping @Sendable () async throws -> TextGenerationClient,
         timeout: TimeInterval = 15) {
        self.loadClient = loadClient
        self.timeout = timeout
    }

    /// Production loader: the configured text provider. Settings live on the
    /// main actor, and the key is re-read per decision so a newly saved
    /// provider starts working without a restart.
    @MainActor
    init(settings: TextProviderSettings? = nil, timeout: TimeInterval = 15) {
        let settings = settings ?? .shared
        self.init(loadClient: { try await MainActor.run { try settings.client() } },
                  timeout: timeout)
    }

    /// One decision per utterance. Transport faults (timeout, offline,
    /// dropped connection) get exactly one bounded retry; provider and
    /// configuration errors never retry; a malformed reply retries once —
    /// then refuses honestly.
    func decide(utterance: String, context: PlannerContext) async throws -> PlannerDecision {
        let client = try await loadClient()
        let user = Self.renderUser(utterance: utterance, context: context)
        var transportError: Error?
        for attempt in 0..<2 {
            do {
                let text = try await client.chat(system: Self.systemPrompt,
                                                 user: user, json: true, timeout: timeout)
                return try Self.decodeDecision(text)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as TextGenerationClient.Failure {
                throw failure
            } catch let failure as Failure {
                if attempt == 0 { continue }
                throw failure
            } catch {
                transportError = error
                if attempt == 0 {
                    try await Task.sleep(for: .milliseconds(300))
                    continue
                }
                throw error
            }
        }
        throw transportError ?? Failure.malformedDecision
    }

    /// The planner's whole world fits in the request body: the utterance plus
    /// the lean `PlannerContext` — recent intents, one pending question or
    /// consent, the agent roster, and a foreground hint.
    static func renderUser(utterance: String, context: PlannerContext) -> String {
        var object: [String: JSONValue] = ["utterance": .string(utterance)]
        if !context.recentIntents.isEmpty {
            object["recent_intents"] = .array(context.recentIntents.suffix(8).map { .string($0) })
        }
        if let clarify = context.pendingClarify {
            object["pending_question"] = .object([
                "question": .string(clarify.question),
                "options": .array(clarify.options.map { .string($0) })
            ])
        }
        if let consent = context.pendingConsent {
            object["pending_consent"] = .object([
                "id": .string(consent.id),
                "summary": .string(consent.summary),
                "reason": .string(consent.reason)
            ])
        }
        if !context.agents.isEmpty {
            object["agents"] = .array(context.agents.map { agent in
                .object(["slug": .string(agent.slug),
                         "name": .string(agent.name),
                         "role": .string(agent.role)])
            })
        }
        if !context.tasks.isEmpty {
            object["tasks"] = .array(context.tasks.map { task in
                .object(["id": .string(task.intentID.uuidString),
                         "request": .string(task.request),
                         "status": .string(task.status),
                         "application": task.application.map { .string($0) } ?? .null])
            })
        }
        if !context.questions.isEmpty {
            object["questions"] = .array(context.questions.map { question in
                .object(["id": .string(question.questionID.uuidString),
                         "prompt": .string(question.prompt),
                         "options": .array(question.options.map { .string($0) })])
            })
        }
        if let hint = context.foregroundHint, !hint.isEmpty {
            object["foreground_app"] = .string(hint)
        }
        object["utterance_final"] = .bool(context.utteranceFinal)
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Strict, bounded decode: only the documented shapes produce decisions,
    /// required fields must be non-empty, unknown `type`s refuse. Anything
    /// else is `malformedDecision` — never a guessed action.
    static func decodeDecision(_ text: String) throws -> PlannerDecision {
        guard let object = try? JSONDecoder().decode(JSONValue.self,
                                                     from: Data(text.utf8)),
              case let .object(fields) = object,
              let type = fields["type"]?.string else { throw Failure.malformedDecision }
        func field(_ name: String) -> String? {
            guard let value = fields[name]?.string else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func uuid(_ name: String) -> UUID? { field(name).flatMap(UUID.init(uuidString:)) }
        func relationship(_ fields: [String: JSONValue]) -> TaskRelationship {
            let kind = field("relationship") ?? "independent"
            guard let id = uuid("related_intent") ?? uuid("relatedIntent") else { return .independent }
            switch kind {
            case "continuation": return .continuation(of: id)
            case "correction": return .correction(of: id)
            default: return .independent
            }
        }
        func strings(_ name: String) -> [String] {
            fields[name]?.array?.compactMap { $0.string }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        }
        switch type {
        case "execute":
            guard let goal = field("goal") else { throw Failure.malformedDecision }
            var values: [String: String] = [:]
            for (key, value) in fields["values"]?.object ?? [:] {
                if let text = value.string, !key.isEmpty { values[key] = text }
            }
            return .execute(TaskSpec(
                goal: goal,
                application: field("application"),
                scope: TaskSpec.Scope(rawValue: field("scope") ?? "work") ?? .work,
                window: field("window"),
                deny: strings("deny"),
                values: values,
                literalText: field("literal_text") ?? field("literalText"),
                successContains: strings("success_contains"),
                resolvesPendingQuestion: fields["resolves_question"] == .bool(true)
                    || fields["resolvesQuestion"] == .bool(true),
                answersQuestionID: uuid("answers_question") ?? uuid("answersQuestion"),
                relationship: relationship(fields),
                requiresIntentID: uuid("requires_intent") ?? uuid("requiresIntent"),
                consumedThrough: fields["consumed_through"]?.integer
                    ?? fields["consumedThrough"]?.integer))
        case "clarify":
            guard let question = field("question") else { throw Failure.malformedDecision }
            return .clarify(ClarifyRequest(question: question, options: strings("options")))
        case "answer":
            guard let answer = field("text") ?? field("answer") else { throw Failure.malformedDecision }
            return .answer(text: answer)
        case "consent":
            guard let summary = field("summary") else { throw Failure.malformedDecision }
            return .consentNeeded(ConsentRequest(summary: summary,
                                                 reason: field("reason") ?? "input approval"))
        case "refuse":
            return .refuse(reason: field("reason") ?? "I can't do that.")
        case "delegate":
            guard let message = field("message") else { throw Failure.malformedDecision }
            return .delegate(DelegationRequest(
                agentSlug: field("agent_slug") ?? field("agentSlug"),
                newAgentName: field("new_agent_name") ?? field("newAgentName"),
                newAgentRole: field("new_agent_role") ?? field("newAgentRole"),
                newAgentDescription: field("new_agent_description") ?? field("newAgentDescription"),
                message: message))
        case "send_to_agent", "sendToAgent":
            guard let slug = field("slug") ?? field("agent_slug") ?? field("agentSlug"),
                  let message = field("message") else { throw Failure.malformedDecision }
            return .sendToAgent(slug: slug, message: message)
        case "agent_memory", "agentMemory":
            guard let slug = field("slug") ?? field("agent_slug") ?? field("agentSlug")
            else { throw Failure.malformedDecision }
            return .agentMemory(slug: slug)
        case "cancel":
            return .cancel(CancelRequest(
                targetIntentID: uuid("target_intent") ?? uuid("targetIntent"),
                consumedThrough: fields["consumed_through"]?.integer))
        case "stop_all", "stopAll":
            return .cancel(CancelRequest(consumedThrough: fields["consumed_through"]?.integer))
        case "correct":
            var replacement: TaskSpec?
            if let goal = field("replacement_goal") {
                replacement = TaskSpec(goal: goal, application: field("application"),
                                       scope: TaskSpec.Scope(rawValue: field("scope") ?? "work") ?? .work)
            }
            return .correct(CorrectionRequest(
                targetIntentID: uuid("target_intent") ?? uuid("targetIntent"),
                mode: field("mode") == "revise" ? .revise : .retract,
                replacement: replacement,
                consumedThrough: fields["consumed_through"]?.integer))
        case "retry":
            return .retry(RetryRequest(
                targetIntentID: uuid("target_intent") ?? uuid("targetIntent"),
                consumedThrough: fields["consumed_through"]?.integer))
        default:
            throw Failure.malformedDecision
        }
    }

    private static let systemPrompt = """
        You are the companion planner inside Jev Voice, a macOS voice assistant. \
        For each utterance you make exactly ONE decision and reply with a single \
        JSON object — no prose, no markdown, no code fences.

        Decisions:
        {"type":"execute","goal":"…","application":"…","scope":"open|create|work","window":null,"deny":[],"values":{},"literal_text":null,"success_contains":[]}
        {"type":"clarify","question":"…","options":["…"]}
        {"type":"answer","text":"…"}
        {"type":"consent","summary":"…","reason":"…"}
        {"type":"refuse","reason":"…"}
        {"type":"delegate","agent_slug":null,"new_agent_name":null,"new_agent_role":null,"new_agent_description":null,"message":"…"}
        {"type":"send_to_agent","slug":"…","message":"…"}
        {"type":"agent_memory","slug":"…"}
        {"type":"cancel","target_intent":null}
        {"type":"stop_all"}
        {"type":"correct","target_intent":"…","mode":"retract|revise","replacement_goal":null}
        {"type":"retry","target_intent":null}

        Rules:
        - "execute" is only for computer work the app performs: opening apps, \
        typing user-supplied text, working a window's UI. A per-step engine \
        drives the window afterward, so `goal` is one literal sentence naming \
        the end state — never a list of clicks.
        - `application` is the target app's name or bundle id when the request \
        names or implies one; null otherwise. `window` is a window title the \
        user named, else null.
        - `scope`: "open" = only launch/show the app; "create" = a new \
        top-level document or window; "work" = everything else, including \
        tabs, notes and entries inside an existing window.
        - `literal_text` carries only words the user dictated verbatim for \
        insertion ("type hello", 'enter "hi"') — copy the user's exact words, \
        never invent or paraphrase content. `values` maps field labels to text \
        the user supplied.
        - `deny` lists label substrings the driver must never press; \
        `success_contains` lists strings whose observed presence proves the \
        goal.
        - "clarify" when a missing detail would pick the wrong target or \
        action (which app, window, recipient, or text). Ask one short \
        question; offer concrete options in `options` when known. Never ask \
        about what the request already states.
        - "answer" for utterances needing no computer action: questions, \
        status checks, conversation. `text` is what the user hears/reads.
        - "consent" only when the next step needs an input-approval ask the \
        user must grant first; `summary` is the plain ask shown and spoken.
        - "refuse" for anything that cannot be done safely or at all; `reason` \
        is one honest sentence.
        - "delegate" hands durable background work to a persistent agent — \
        research, watch-and-report, scheduled or multi-turn tasks that outlive \
        this interaction. Prefer an existing roster agent by slug over \
        founding a twin; `message` is the user's own brief in first person.
        - "send_to_agent" routes a follow-up to the agent in context; \
        "agent_memory" reads an agent's findings without waking it.
        - "cancel" stops work the user named: `target_intent` is the `id` from \
        `tasks` the user meant, null only when exactly one task is live. \
        "stop_all" is a bare "stop everything" with no named target.
        - "correct" handles "undo that / actually never mind that / close it \
        back": `target_intent` names the earlier `tasks` id; `mode` is \
        "retract" to withdraw or unwind it, "revise" when the user supplies \
        replacement wording — then `replacement_goal` carries the new one-line \
        goal.
        - "retry" only for an explicit "try that again / do it again" after a \
        task failed or ended uncertain; `target_intent` names it when the user \
        does. Never retry on your own initiative.
        - `tasks` lists live and recent intents with their `id`, `request`, \
        and `status`; target ids come only from that list — never invent one. \
        `questions` lists live pending asks; an `execute` answering one sets \
        `answers_question` to that `id`.
        - An utterance naming several requests ("open Notes then send it") \
        decides only the first request and sets `consumed_through` to the word \
        index it ends at; the remainder is judged on its own.
        - When `pending_question` is set and the utterance answers it, emit \
        the decision the completed request implies — usually "execute" whose \
        `goal` folds the answer in (the named answer becomes `window` or a \
        `values` entry as fits) — and set `resolves_question` true. An \
        utterance that ignores the question is judged normally without it.
        - When `pending_consent` is set, a bare "yes"/"no" resolves that ask — \
        emit nothing for it yourself; any other utterance is judged normally.
        - Literal payloads and `values` come only from the utterance. If the \
        utterance is filler, incomplete, or carries no request, clarify or \
        refuse — never execute a guess.
        """
}

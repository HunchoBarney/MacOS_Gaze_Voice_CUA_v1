import Foundation
import JevVoiceCore

/// Drive-loop seam — Clicky's `drive_until` executor. L1's `CuaAgentLoop`
/// plugs in at integration; tests use a recording stub.
protocol DriveExecuting: Sendable {
    func drive(_ task: DriveTask) async throws -> DriveResult
}

/// Lane-arbitration seam — the subset of `CuaLaneRegistry` the agent
/// surfaces consume. The shared actor satisfies it at integration; tests
/// record acquisitions on a stub.
protocol AgentLaneLeasing: Sendable {
    func acquire(app: String, pid: Int?, workID: String) async throws
    func acquireFocus(workID: String) async throws
    func acquirePasteboard(workID: String) async throws
    func releaseAll(workID: String) async
}

extension CuaLaneRegistry: AgentLaneLeasing {}

/// Advisory single-step seam — Clicky's `suggest_action` (TypeSafe Jev).
/// Never acts, never generates text.
protocol ActionSuggesting: Sendable {
    func suggestAction(pid: Int, windowID: Int) async throws -> StepJudgment
}

/// jev-use surface — Clicky's `ClickyJevUseMCPServer`. Agents hand
/// single-window driving to TypeSafe Jev through these two tools; the server
/// itself only validates arguments and marshals results.
struct JevUseMCPServer: Sendable {
    private let executor: any DriveExecuting
    private let suggester: (any ActionSuggesting)?
    /// drive_until mutates the desktop through the loop's internal driver
    /// calls — without a gate here an agent could bypass the consent shim
    /// entirely. One approval arms the whole call's steps for this turn.
    /// The gate resolves the agent's live turn itself, so one "yes" covers
    /// both tool surfaces.
    private let consent: ComputerUseGate?
    private let agentSlug: String?

    init(executor: any DriveExecuting, suggester: (any ActionSuggesting)? = nil,
         consent: ComputerUseGate? = nil, agentSlug: String? = nil) {
        self.executor = executor
        self.suggester = suggester
        self.consent = consent
        self.agentSlug = agentSlug
    }

    /// The loopback endpoint the coordinator writes into `mcp_servers`.
    func server(token: String? = nil) -> LoopbackMCPServer {
        LoopbackMCPServer(serverName: "jev-use", token: token,
            // suggest_action only advertises when wired — a listed tool that
            // always answers "unavailable" burns agent turns on a dead door.
            tools: { Self.tools(includeSuggest: self.suggester != nil) },
            onCall: { name, args in try await self.callTool(name, arguments: args) })
    }

    /// tools/call entry — returns the MCP tool-result object.
    func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        let args = arguments.object ?? [:]
        switch name {
        case JevUseTools.driveUntil:
            guard let goal = args["goal"]?.string, !goal.isEmpty else {
                return Self.error("invalid_arguments", "drive_until needs a non-empty \"goal\" string.")
            }
            var task = DriveTask(goal: goal)
            task.application = args["application"]?.string
            task.pid = args["pid"]?.integer
            task.windowID = args["window_id"]?.integer
            task.values = Self.stringMap(args["values"])
            task.deny = Self.stringList(args["deny"])
            task.successContains = Self.stringList(args["success_contains"])
            if let maxSteps = args["max_steps"]?.integer, maxSteps > 0 { task.maxSteps = maxSteps }
            do {
                try consent?.assertPermittedNow(tool: JevUseTools.driveUntil, agentSlug: agentSlug)
            } catch GateError.blockedByConsent(let summary) {
                return Self.error("blocked_by_consent", summary)
            }
            return Self.result(Self.driveResultJSON(try await executor.drive(task)))
        case JevUseTools.suggestAction:
            guard let pid = args["pid"]?.integer, let windowID = args["window_id"]?.integer else {
                return Self.error("invalid_arguments", "suggest_action needs integer \"pid\" and \"window_id\".")
            }
            guard let suggester else {
                return Self.error("unavailable", "suggest_action is not wired in this build.")
            }
            return Self.result(Self.judgmentJSON(try await suggester.suggestAction(pid: pid, windowID: windowID)))
        default:
            return Self.error("unknown_tool", "Unknown tool \"\(name)\".")
        }
    }

    /// Clicky's tool surface, verbatim: drive_until takes the goal plus the
    /// caller's literal values/deny list; suggest_action takes a window.
    /// `includeSuggest` keeps the second tool honest — it is only listed
    /// when a suggester is actually wired (see `server(token:)`).
    static func tools(includeSuggest: Bool = true) -> [JSONValue] {
        var list: [JSONValue] = [
            .object([
            "name": .string(JevUseTools.driveUntil),
            "description": .string("Drive one window toward a literal end state. Jev selects elements and never writes text — caller-supplied text goes in \"values\" keyed by field label, and \"deny\" labels are never pressed."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "goal": .object(["type": .string("string"),
                        "description": .string("One literal sentence naming the end state.")]),
                    "application": .object(["type": .string("string"),
                        "description": .string("Bundle id preferred, app name accepted.")]),
                    "pid": .object(["type": .string("integer")]),
                    "window_id": .object(["type": .string("integer")]),
                    "values": .object(["type": .string("object"),
                        "additionalProperties": .object(["type": .string("string")]),
                        "description": .string("Field label -> literal text supplied by the caller.")]),
                    "deny": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                        "description": .string("Element label substrings Jev must never press.")]),
                    "success_contains": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "max_steps": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("goal")])
            ])
            ])
        ]
        if includeSuggest {
            list.append(.object([
            "name": .string(JevUseTools.suggestAction),
            "description": .string("One advisory step on a window's accessibility tree: element token, kind, confidence, done/blocked readings. Never acts and never generates text; confidence below 0.5 is guessing."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "pid": .object(["type": .string("integer")]),
                    "window_id": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("pid"), .string("window_id")])
            ])
            ]))
        }
        return list
    }

    private static func driveResultJSON(_ result: DriveResult) -> JSONValue {
        var status = "", reason: String?
        switch result.status {
        case .done: status = "done"
        case .alreadySatisfied(let message): status = "already_satisfied"; reason = message
        case .handedBack(let handBack): status = "handed_back"; reason = handBack.rawValue
        case .blocked(let message): status = "blocked"; reason = message
        case .needsText(let field): status = "needs_text"; reason = field
        case .needsWindow(let candidates):
            status = "needs_window"; reason = candidates.joined(separator: ", ")
        case .blockedByConsent(let message): status = "blocked_by_consent"; reason = message
        case .maxSteps: status = "max_steps"
        case .cancelled: status = "cancelled"
        }
        var object: [String: JSONValue] = [
            "status": .string(status),
            "history": .array(result.history.map(JSONValue.string))
        ]
        if let reason { object["reason"] = .string(reason) }
        if let pid = result.pid { object["pid"] = .number(Double(pid)) }
        if let windowID = result.windowID { object["window_id"] = .number(Double(windowID)) }
        return .object(object)
    }

    private static func judgmentJSON(_ judgment: StepJudgment) -> JSONValue {
        .object([
            "element_token": judgment.elementToken.map(JSONValue.string) ?? .null,
            "kind": .string(judgment.kind.rawValue),
            "confidence": .number(judgment.confidence),
            "done": .bool(judgment.done),
            "blocked": judgment.blocked.map(JSONValue.string) ?? .null,
            "fill_tokens": .array(judgment.fillTokens.map(JSONValue.string))
        ])
    }

    private static func stringList(_ value: JSONValue?) -> [String] {
        value?.array?.compactMap(\.string) ?? []
    }

    private static func stringMap(_ value: JSONValue?) -> [String: String] {
        value?.object?.compactMapValues(\.string) ?? [:]
    }

    private static func result(_ structured: JSONValue) -> JSONValue {
        let text = (try? JSONEncoder().encode(structured)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .object([
            "structuredContent": structured,
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ])
    }

    private static func error(_ code: String, _ message: String) -> JSONValue {
        .object([
            "isError": .bool(true),
            "structuredContent": .object(["code": .string(code), "message": .string(message)]),
            "content": .array([.object(["type": .string("text"), "text": .string(message)])])
        ])
    }
}

/// Clicky's `suggest_action` over the agent's own driver: snapshot the bound
/// window, project its interactive elements into one flat choice list, and
/// let a single systemOne call pick. Advisory only — nothing is dispatched,
/// so it rides the observation path (no consent gate) and its candidate
/// projection mirrors the drive loop's element filter (enabled elements in
/// click/text/value roles, bounded).
struct AgentActionSuggester: ActionSuggesting {
    typealias Call = @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    typealias Judge = @Sendable (JSONValue, [String: Question]) async throws -> [String: Answer]

    private static let maximumCandidates = 24

    private let call: Call
    private let judge: Judge

    init(call: @escaping Call, judge: @escaping Judge) {
        self.call = call; self.judge = judge
    }

    init(call: @escaping Call, apiKey: @escaping @Sendable () -> String) {
        self.init(call: call, judge: { state, questions in
            try await JevClient(apiKey: apiKey()).systemOne(state: state, questions: questions)
                .response.answers
        })
    }

    func suggestAction(pid: Int, windowID: Int) async throws -> StepJudgment {
        let snapshot = try await call("get_window_state", [
            "pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
            "include_screenshot": .bool(false), "max_elements": .number(200)])
        let elements = snapshot["elements"]?.array ?? []
        var candidates: [String: (token: String, kind: StepJudgment.Kind)] = [:]
        var criteria: [String: String?] = [:]
        for element in elements {
            guard candidates.count < Self.maximumCandidates else { break }
            guard element["enabled"] != .bool(false) else { continue }
            let role = element["role"]?.string ?? ""
            let index = element["element_index"]?.integer ?? -1
            guard index >= 0, !role.isEmpty else { continue }
            let kind: StepJudgment.Kind
            if Self.textRoles.contains(role) { kind = .type }
            else if Self.clickRoles.contains(role) || Self.valueRoles.contains(role) { kind = .press }
            else { continue }
            let token = element["element_token"]?.string ?? String(index)
            // Label or title first, then AX description/help — icon-only
            // controls name themselves there, and a bare `""` gives the
            // judge nothing to pick on.
            let name = CuaActionCatalog.elementName(element)
            let detail = CuaActionCatalog.elementDetail(element, name: name)
                .map { " — \($0)" } ?? ""
            let id = "e\(index)"
            candidates[id] = (token, kind)
            criteria[id] = (kind == .type
                ? "Type into \(role) \"\(name)\""
                : "Press \(role) \"\(name)\"") + detail
        }
        guard !candidates.isEmpty else {
            return StepJudgment(kind: .none, confidence: 0,
                                blocked: "no_interactive_elements")
        }
        criteria["none"] = "No element action is useful from this state."
        let state: JSONValue = .object([
            "pid": .number(Double(pid)),
            "window_id": .number(Double(windowID)),
            "window_title": .string(snapshot["window"]?["title"]?.string
                ?? snapshot["title"]?.string ?? snapshot["window_title"]?.string ?? ""),
            "elements": .array(elements.prefix(80).map(Self.compactElement))])
        let answers = try await judge(state, [
            "next": .choice(
                instructions: "Choose the single most useful next action on this window. This is advisory — nothing is dispatched. \"Press\" criteria activate a control; \"Type into\" criteria focus a text field for caller-supplied text — when the useful step is entering text, prefer the type lane over a press that merely reveals the field. Pick none only when no element action is clearly useful.",
                criteria: criteria)])
        let confidence = answers["next"].flatMap { answer -> Double? in
            if case .choice(_, let confidence, _) = answer { return confidence }
            return nil
        } ?? 0
        guard let picked = try? JevSelection.read(answers["next"], allowed: Set(criteria.keys)),
              picked != "none", let candidate = candidates[picked] else {
            return StepJudgment(kind: .none, confidence: confidence)
        }
        return StepJudgment(elementToken: candidate.token, kind: candidate.kind,
                            confidence: confidence)
    }

    /// The same compact element shape the drive loop's state carries —
    /// index, role, label, value — so a suggestion reads the window the way
    /// the loop does.
    private static func compactElement(_ element: JSONValue) -> JSONValue {
        .object([
            "i": element["element_index"] ?? .null,
            "role": element["role"] ?? .null,
            "label": element["label"] ?? element["title"] ?? .null,
            "value": (element["value"]?.string).map { .string(String($0.prefix(80))) } ?? .null])
    }

    private static let clickRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
        "AXPopUpButton", "AXComboBox", "AXTab", "AXLink", "AXImage",
        "AXCell", "AXRow", "AXOutlineRow", "AXDisclosureTriangle", "AXIncrementor",
        "AXSlider", "AXSegment", "AXToolbarButton", "AXScrollBar", "AXSwitch"]

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    private static let valueRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXSlider", "AXSwitch", "AXStepper", "AXIncrementor"]
}

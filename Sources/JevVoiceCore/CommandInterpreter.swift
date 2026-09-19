import Foundation

public enum CommandInterpretationError: Error, LocalizedError {
    case missingDictationPrefix

    public var errorDescription: String? {
        "To dictate text, start with type, write, dictate, or say, followed by the text to enter."
    }
}

public final class CommandInterpreter {
    private let client: JevClient
    private let installedApps: [String]

    public init(client: JevClient, installedApps: [String]) {
        self.client = client
        self.installedApps = installedApps
    }

    struct State: Encodable {
        let clause: String
        let fullTranscript: String
        let frontmostApp: String?
        let installedApps: [String]
        let clauses: [String]
        let clauseIndex: Int

        enum CodingKeys: String, CodingKey {
            case clause
            case fullTranscript = "full_transcript"
            case frontmostApp = "frontmost_app"
            case installedApps = "installed_apps"
            case clauses
            case clauseIndex = "clause_index"
        }
    }

    public func interpret(transcript: String, frontmostApp: String?) async throws -> [Decision] {
        let clauses = ClauseSplitter.split(transcript)
        // A clause shortcut must not strip conditions from the rest of the request.
        // Only bypass interpretation when the complete composition is locally understood.
        let allowLocalNavigation = clauses.allSatisfy {
            AppMatcher.explicitNavigation(clause: $0, installedApps: installedApps) != nil
                || SlotExtractor.literalDictationSuffix(from: $0) != nil
        }
        return try await withThrowingTaskGroup(of: (Int, InterpretedClause).self) { group in
            for (index, clause) in clauses.enumerated() {
                group.addTask {
                    let decision = try await self.interpretClause(
                        clause, transcript: transcript, frontmostApp: frontmostApp,
                        clauses: clauses, index: index, allowLocalNavigation: allowLocalNavigation
                    )
                    return (index, decision)
                }
            }
            var ordered: [(Int, InterpretedClause)] = []
            for try await result in group { ordered.append(result) }
            return try CommandPlanner.plan(ordered.sorted { $0.0 < $1.0 }.map { $0.1 }, frontmostApp: frontmostApp)
        }
    }

    private func interpretClause(
        _ clause: String, transcript: String, frontmostApp: String?, clauses: [String], index: Int,
        allowLocalNavigation: Bool
    ) async throws -> InterpretedClause {
        if let text = SlotExtractor.literalDictationSuffix(from: clause) {
            let action: Action = text.isEmpty ? .none : .dictate
            return InterpretedClause(decision: Decision(
                clause: clause,
                action: action,
                actionProbabilities: [action.rawValue: 1],
                text: text.isEmpty ? nil : text,
                confidence: 1,
                model: "local-dictation"
            ), context: action == .dictate ? (index > 0 ? .previous : .frontmost) : .independent)
        }

        if index == 0, let url = SlotExtractor.namedWebsiteURL(from: clause) {
            return InterpretedClause(decision: Decision(
                clause: clause, action: .openURL,
                actionProbabilities: [Action.openURL.rawValue: 1],
                url: url, confidence: 1, model: "local-navigation"
            ))
        }

        if allowLocalNavigation, let navigation = AppMatcher.explicitNavigation(clause: clause, installedApps: installedApps) {
            return InterpretedClause(decision: Decision(
                clause: clause, action: navigation.action,
                actionProbabilities: [navigation.action.rawValue: 1], targetApp: navigation.app,
                confidence: 1, model: "local-app-navigation"
            ))
        }

        var appCriteria: [String: String?] = ["none": "No application mentioned"]
        // Dictionary subscript assignment of nil removes the key, even when the
        // value is Optional. Keep each candidate with an encoded JSON null.
        for app in installedApps.prefix(254) { appCriteria.updateValue(nil, forKey: app) }

        var actionCriteria: [String: String?] = [:]
        for action in Action.allCases { actionCriteria[action.rawValue] = action.description }

        var systemCriteria: [String: String?] = [:]
        for action in SystemAction.allCases { systemCriteria[action.rawValue] = action.description }

        var contextCriteria: [String: String?] = [
            "independent": "Starts a task with its own execution context, explicitly switches to a different app/site, or has no target (such as changing volume). A URL after opening a browser is NOT independent: it uses that browser.",
            "frontmost": "Explicitly refers to the app active before the entire utterance. Do not choose this for it/there referring to an app named earlier in the utterance.",
        ]
        if index > 0 {
            contextCriteria["previous"] = "Continue using the most recent earlier app/site, with NO request for separate tabs/windows. Includes open a browser then visit a URL, open a site then search, or open an app then minimize it. The new URL or query is an argument, not a change of browser."
            contextCriteria["previousSeparate"] = "Continue in the earlier app/site AND explicitly request an additional/separate tab/window or keeping the preparatory page open. Merely saying and/then is NOT a request for separate tabs."
        }

        let questions: [String: Question] = [
            "action": .choice(
                instructions: "Select the action for `clauses[clause_index]` within `full_transcript`. Other clauses are context, not extra actions for this step. Opening an app or website can be preparation for the next clause. webSearch includes searching within a named website or app; do not replace that destination with a general web search. Never infer actions from literal dictation text.",
                criteria: actionCriteria
            ),
            "target_app": .choice(
                instructions: "Which installed application is explicitly targeted by `clauses[clause_index]`? For a website in a named browser, choose that browser. For an in-app search, choose that app. For an omitted target or a reference to an earlier step, choose none; target_context resolves references. Do not guess the user's preferred browser.",
                criteria: appCriteria
            ),
            "system_action": .choice(
                instructions: "Which system action does the clause request? Clause: \"\(clause)\"",
                criteria: systemCriteria
            ),
            "target_context": .choice(
                instructions: "Resolve the execution context of `clauses[clause_index]` from the ordered `clauses` and `full_transcript`. Earlier clauses are planned, not executed yet. Distinguish the application/site in which to act from the URL, query, or text supplied to that action. Continue the last established context unless the user requests a different one. Never reference a future clause.",
                criteria: contextCriteria
            ),
            "search_site": .choice(
                instructions: "If `clauses[clause_index]` requests search, identify its explicitly named website or service. Choose unsupported for any named search destination outside the listed websites. Choose none ONLY when no search destination is named or it is inherited from an earlier clause. Do not mistake words inside the search query for its destination.",
                criteria: Dictionary(uniqueKeysWithValues: [("none", Optional("Search destination omitted or inherited")), ("unsupported", Optional("Explicit search inside another website or service, outside the supported choices"))] + SearchSite.allCases.map { ($0.rawValue, Optional("Search within \($0.rawValue)")) })
            ),
        ]

        let state = State(
            clause: clause,
            fullTranscript: transcript,
            frontmostApp: frontmostApp,
            installedApps: installedApps, clauses: clauses, clauseIndex: index
        )
        let (response, latencyMs) = try await client.systemOne(state: state, questions: questions)

        var action = Action.none
        var actionProbs: [String: Double] = [:]
        var actionConfidence = 0.0
        if case .choice(let choice, let confidence, let probs) = response.answers["action"] {
            action = Action(rawValue: choice) ?? .none
            actionProbs = probs
            actionConfidence = confidence
        }

        // Explicit literal clauses return before the model call. A model-selected
        // dictation has no trusted text boundary and must be clarified before execution.
        if action == .dictate {
            throw CommandInterpretationError.missingDictationPrefix
        }

        var targetApp: String?
        var targetProbs: [String: Double] = [:]
        var targetConfidence = 1.0
        if case .choice(let choice, let confidence, let probs) = response.answers["target_app"] {
            targetProbs = probs
            targetConfidence = confidence
            if choice != "none" { targetApp = choice }
        }

        var systemAction: SystemAction?
        var systemConfidence = 1.0
        if case .choice(let choice, let confidence, _) = response.answers["system_action"] {
            systemConfidence = confidence
            let parsed = SystemAction(rawValue: choice) ?? .none
            if parsed != .none { systemAction = parsed }
        }

        var context = TargetContext.independent
        var contextConfidence = 1.0
        if case .choice(let choice, let confidence, _) = response.answers["target_context"] {
            context = TargetContext(rawValue: choice) ?? .independent
            contextConfidence = confidence
        }
        let refersToFrontmost = context == .frontmost
        let inherits = context == .previous || context == .previousSeparate
        var searchSite: SearchSite?
        var siteConfidence = 1.0
        var unsupportedSearchSite = false
        if case .choice(let choice, _, _) = response.answers["search_site"] {
            unsupportedSearchSite = choice == "unsupported"
        }
        if case .choice(let choice, let confidence, _) = response.answers["search_site"],
           let site = SearchSite(rawValue: choice) {
            searchSite = site
            siteConfidence = confidence
        }

        let url = SlotExtractor.url(from: clause)
        var query = SlotExtractor.searchQuery(from: clause, site: searchSite)
        let text = SlotExtractor.dictationText(from: clause)
        let percent = SlotExtractor.numberPercent(from: clause)

        if action == .openApp && url != nil {
            action = .openURL
        }
        if action == .openURL && url == nil, let q = query {
            action = .webSearch
            query = q
        }
        if action == .webSearch && unsupportedSearchSite {
            throw PlanningError.unsupportedSearch("the requested destination")
        }
        let localMatch = refersToFrontmost || inherits
            ? nil : AppMatcher.match(clause: clause, installedApps: installedApps)
        // Do not turn a full-context no-action answer into an app action merely
        // because a name appears inside a conditional or otherwise deferred request.
        if url == nil, action != .none, action != .openURL, action != .webSearch, action != .dictate,
           let verbAction = AppMatcher.verbAction(clause: clause), let local = localMatch,
           local.confidence >= 0.8 {
            action = verbAction
            actionConfidence = max(actionConfidence, 0.95)
            targetApp = local.app
            targetConfidence = local.confidence
            systemAction = nil
            systemConfidence = 1.0
        }
        if targetApp == nil && Action.appTargeted.contains(action) && !inherits {
            if refersToFrontmost {
                if action != .openApp, let front = frontmostApp {
                    targetApp = front
                } else {
                    action = .none
                }
            } else if let local = localMatch {
                targetApp = local.app
                targetConfidence = local.confidence
            }
        }
        if action == .openURL,
           let app = targetApp,
           !CommandPlanner.browserNames.contains(app.lowercased()) {
            targetApp = nil
        }
        if action == .system && systemAction == nil {
            systemAction = SystemAction.none
        }
        if systemAction != nil && action == .none {
            action = .system
        }

        // Only the selected action's arguments can hold up that action.
        // Speculative system answers are irrelevant to a browser/app command.
        var confidence = actionConfidence
        if !inherits && !refersToFrontmost && (Action.appTargeted.contains(action) ||
            ((action == .openURL || action == .webSearch) && targetApp != nil)) {
            confidence = min(confidence, targetConfidence)
        }
        if action == .system {
            confidence = min(confidence, systemConfidence)
        }
        if action == .webSearch && !inherits { confidence = min(confidence, siteConfidence) }

        return InterpretedClause(decision: Decision(
            clause: clause,
            action: action,
            actionProbabilities: actionProbs,
            targetApp: targetApp,
            targetAppProbabilities: targetProbs,
            systemAction: systemAction,
            url: url,
            query: query,
            text: text,
            percent: percent,
            confidence: confidence,
            latencyMs: latencyMs,
            model: response.model,
            searchSite: searchSite
        ), context: context, contextConfidence: contextConfidence)
    }
}

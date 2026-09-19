import Foundation

/// How a clause relates to the rest of the utterance. This is a model judgment;
/// resolving targets and deciding whether actions can be combined is code.
enum TargetContext: String {
    case independent, previous, previousSeparate, frontmost
}

struct InterpretedClause {
    var decision: Decision
    var context: TargetContext = .independent
    var contextConfidence: Double = 1
}

enum PlanningError: LocalizedError {
    case missingPreviousTarget
    case unsupportedSearch(String)
    case unsupportedNavigation(String)
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingPreviousTarget: return "I couldn't resolve which app or website the next step refers to. Please name it."
        case .unsupportedSearch(let target): return "Searching inside \(target) isn't supported yet. I haven't run any steps."
        case .unsupportedNavigation(let target): return "Opening websites inside \(target) isn't supported. I haven't run any steps."
        case .missingArgument(let name): return "I couldn't identify the \(name). Please include it in your command."
        }
    }
}

enum CommandPlanner {
    static let browserNames: Set<String> = [
        "safari", "google chrome", "chrome", "firefox", "arc", "brave browser",
        "microsoft edge", "opera", "vivaldi", "orion", "duckduckgo",
    ]

    static func plan(_ clauses: [InterpretedClause], frontmostApp: String?) throws -> [Decision] {
        var plan: [Decision] = []
        var target = frontmostApp.map {
            Decision(clause: "App active before recording", action: .switchApp, targetApp: $0, confidence: 1)
        }
        for clause in clauses {
            var step = clause.decision
            if step.action != .system && step.action != .none {
                step.confidence = min(step.confidence, clause.contextConfidence)
            }
            let previous = plan.last
            let inherits = clause.context == .previous || clause.context == .previousSeparate
            if inherits {
                guard let target else {
                    throw PlanningError.missingPreviousTarget
                }
                // A continuation must use the earlier resolved target, not a
                // speculative target chosen independently in another question.
                step.targetApp = target.targetApp
                step.confidence = min(step.confidence, target.confidence, clause.contextConfidence)
                if step.action == .webSearch {
                    if let url = target.url {
                        guard let site = SearchSite.matching(url: url), site.canSearch(from: url) else {
                            throw PlanningError.unsupportedSearch(URL(string: url)?.host ?? url)
                        }
                        step.searchSite = site
                    } else if let site = target.searchSite {
                        step.searchSite = site
                    }
                }
            } else if clause.context == .frontmost {
                step.targetApp = frontmostApp
                step.confidence = min(step.confidence, clause.contextConfidence)
            }

            if step.action == .webSearch, let app = step.targetApp,
               !browserNames.contains(app.lowercased()) {
                throw PlanningError.unsupportedSearch(app)
            }
            if step.action == .openURL, let app = step.targetApp,
               !browserNames.contains(app.lowercased()) {
                throw PlanningError.unsupportedNavigation(app)
            }
            if step.action == .webSearch {
                if let url = step.url {
                    guard let site = SearchSite.matching(url: url), site.canSearch(from: url) else {
                        throw PlanningError.unsupportedSearch(URL(string: url)?.host ?? url)
                    }
                    step.searchSite = site
                }
                step.searchSite = step.searchSite ?? .google
            }

            // The destination operation already launches the chosen browser.
            // Keep separate windows/tabs when explicitly requested, and keep
            // non-homepage navigation because it may be independently useful.
            if inherits, clause.context != .previousSeparate, let previous,
               step.action == .openURL || step.action == .webSearch {
                let browserLaunch = (previous.action == .openApp || previous.action == .switchApp)
                    && previous.targetApp.map { browserNames.contains($0.lowercased()) } == true
                let searchHomepage = previous.action == .openURL && step.action == .webSearch
                    && previous.url.map(SearchSite.isHomepage) == true
                if browserLaunch || searchHomepage {
                    plan.removeLast()
                    step.clause = previous.clause + " and " + step.clause
                    step.latencyMs = max(previous.latencyMs, step.latencyMs)
                    step.planExplanation = "Combined the opening step with its destination into one navigation."
                }
            }

            switch step.action {
            case .openURL:
                guard let url = step.url, URL(string: url)?.host != nil else { throw PlanningError.missingArgument("website address") }
            case .webSearch:
                guard let query = step.query, !query.isEmpty else { throw PlanningError.missingArgument("search terms") }
            case .openApp, .closeApp, .switchApp, .minimizeApp, .hideApp:
                guard step.targetApp != nil else { throw PlanningError.missingArgument("target app") }
            default: break
            }
            plan.append(step)
            if [.openApp, .switchApp, .openURL, .webSearch].contains(step.action) {
                target = step
            } else if step.action == .closeApp && step.targetApp == target?.targetApp {
                target = nil
            }
        }
        return plan
    }
}

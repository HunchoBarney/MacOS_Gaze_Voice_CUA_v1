import Foundation
import JevVoiceCore
import OSLog

/// One-shot stateless planner — the audit's replacement for the persistent
/// codex app-server tier. A single bounded chat-completions call produces
/// the same advisory `DrivePlan`; no spawn, auth seeding, thread or session
/// state exists to leak. The provider request honors task cancellation, so
/// `planWithBudget`'s race bounds it honestly.
/// Provider order: the user's configured text provider (Commands settings)
/// when it holds a usable key, else the OpenAI key that powers the voice
/// lane. Every failure returns nil — the plain loop still runs.
struct CuaLitePlanner: CuaPlanning {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice",
                                    category: "cua-planner")

    private let makeClient: @Sendable () async -> TextGenerationClient?
    private let timeout: TimeInterval

    init(makeClient: @escaping @Sendable () async -> TextGenerationClient?,
         timeout: TimeInterval = 6) {
        self.makeClient = makeClient; self.timeout = timeout
    }

    /// The shared instance resolves the provider lazily — a key saved in
    /// Settings mid-session takes effect on the next plan, and absence of
    /// any usable key never builds a client at all.
    static let shared = CuaLitePlanner {
        if let client = try? await TextProviderSettings.shared.client() { return client }
        let key = Config.shared.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              let url = try? TextGenerationClient.endpoint("https://api.openai.com/v1")
        else { return nil }
        return TextGenerationClient(baseURL: url, model: "gpt-4o", key: key)
    }

    /// Stateless — nothing to warm; satisfies the protocol's default no-op
    /// contract explicitly for the call-site's readability.
    func warmUp() async {}

    func plan(goal: String, appName: String?, windowTitle: String?,
              previousContext: String?) async -> DrivePlan? {
        guard let client = await makeClient() else { return nil }
        let system = """
        You plan one macOS computer-control request for a grounded executor. \
        Reply with ONLY a JSON object: \
        {"steps": [..], "success_contains": [..], "prefer_visual": bool, "notes": "..."}. \
        steps — 1 to 4 short imperative steps, in order, using plain verbs \
        (open, click, type, scroll, choose from a menu). success_contains — \
        1 to 3 short literal strings that will be visible on screen only when \
        the goal is truly done. prefer_visual — true when the target is \
        rendered content (names, photos, icon-only controls) rather than \
        standard UI elements. notes — one short hazard or tip, else null. \
        Transcribe names exactly as given; never substitute a different app \
        or contact.
        """
        var user = "Goal: \(goal)"
        if let appName, !appName.isEmpty { user += "\nApp: \(appName)" }
        if let windowTitle, !windowTitle.isEmpty { user += "\nWindow: \(windowTitle)" }
        if let previousContext, !previousContext.isEmpty { user += "\nEarlier answers: \(previousContext)" }
        do {
            let text = try await client.chat(system: system, user: user, json: true, timeout: timeout)
            return Self.parse(text)
        } catch {
            Self.log.notice("lite_planner_failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Strict-shape parse — any deviation returns nil, never a partial plan.
    static func parse(_ text: String) -> DrivePlan? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let steps = (object["steps"]?.array?.compactMap(\.string) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let success = (object["success_contains"]?.array?.compactMap(\.string) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var hints = DrivePlan.Hints()
        hints.preferVisual = object["prefer_visual"]?.bool ?? false
        hints.notes = object["notes"]?.string
        guard !steps.isEmpty || !success.isEmpty else { return nil }
        return DrivePlan(steps: steps, successContains: success, hints: hints)
    }
}

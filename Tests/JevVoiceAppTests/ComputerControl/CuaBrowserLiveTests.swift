import AppKit
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaBrowserLiveTests: XCTestCase {
    func testIsolatedFormThroughAgentOptIn() async throws {
        try await runFixture(generatedDraft: false)
    }
    func testSearchNavigationThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_SEARCH_TEST"] == "1" else { throw XCTSkip("Opt-in disposable local search/navigation") }
        try await runFixture(generatedDraft: false, searchNavigation: true)
    }
    func testRepeatedScrollThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_SEARCH_TEST"] == "1" else { throw XCTSkip("Opt-in disposable repeated scrolling") }
        try await runFixture(generatedDraft: false, repeatedScrolling: true)
    }
    func testGeneratedDraftDoesNotSubmitOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_GENERATION_TEST"] == "1" else { throw XCTSkip("Opt-in configured provider fixture") }
        try await runFixture(generatedDraft: true)
    }
    private func runFixture(generatedDraft: Bool, searchNavigation: Bool = false, repeatedScrolling: Bool = false) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_CUA_BROWSER_TEST"] == "1",
              let url = env["JARVIS_FIXTURE_URL"], URL(string: url)?.host == "127.0.0.1" else {
            throw XCTSkip("Opt-in real Jev/Cua with a disposable loopback form")
        }
        let key = try CuaLiveCredential.jev()
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let label = "Jarvis browser fixture \(UUID().uuidString.prefix(6))"
        _ = try await connection.call("start_session", arguments: ["session": .string(label)])
        var ownedPID: Int?
        do {
            let prepared = try await connection.call("browser_prepare", arguments: ["allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")]), "session": .string(label)], timeout: 60)
            let pid = try XCTUnwrap(prepared["prepared_pid"]?.integer); ownedPID = pid
            var windows: [JSONValue] = []
            for _ in 0..<50 {
                let listed = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid))])
                let all = listed["windows"]?.array ?? []
                windows = all.filter { $0["is_on_screen"] == .bool(true) }
                if windows.isEmpty { windows = all.filter { !($0["title"]?.string ?? "").isEmpty } }
                if !windows.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard windows.count == 1 else { throw DriverConnectionError.refused("Disposable browser fixture window is ambiguous.") }
            let window = try XCTUnwrap(windows.first?["window_id"]?.integer)
            let call: CuaTaskAgent.Call = { tool, arguments in
                try await connection.call(tool, arguments: arguments.merging(["session": .string(label)]) { _, b in b })
            }
            let target = try await CuaBrowserTarget.bind(pid: pid, window: window, call: call)
            _ = try await call("browser_navigate", ["target_id": target.target, "tab_id": target.tab, "url": .string(repeatedScrolling ? url + "scrolling" : url)])
            var mutations: [String] = []
            let agent = CuaTaskAgent(call: { tool, arguments in
                // This supporting integration test constrains inventory to its own isolated process.
                if tool == "list_apps" || tool == "get_accessibility_tree" {
                    let live = try await call("get_accessibility_tree", [:])
                    let own = (live["apps"]?.array ?? []).filter { $0["pid"]?.integer == pid }
                    return .object(["apps": .array(own)])
                }
                if !["get_window_state", "get_browser_state", "list_windows"].contains(tool) { mutations.append(tool) }
                return try await call(tool, arguments)
            }, judge: { state, questions in
                if case let .choice(_, choices) = questions["next"] {
                    print("Fixture actions:", choices)
                    print("Fixture generated word count:", state["generated_draft"]?.string?.split(whereSeparator: \.isWhitespace).count ?? 0)
                }
                let answers = try await JevClient(apiKey: key).systemOne(state: state, questions: questions).response.answers
                print("Fixture decision:", answers)
                return answers
            }, windowID: window, generate: generatedDraft ? { prompt, context, reasoning in
                try await TextProviderSettings.shared.client().generate(prompt: prompt, context: context, reasoning: reasoning)
            } : nil, allowConfirmedRepetition: env["JARVIS_CUA_SIMPLIFIED"] == "1",
               payload: { request, purpose in try await JevSpeechIntent(client: JevClient(apiKey: key)).textPayload(request: request, purpose: purpose) })
            let goal = repeatedScrolling
                ? "In Google Chrome in the background, scroll the Scrollable guide down once, then scroll it down one more time. Make exactly two downward scroll actions."
                : searchNavigation
                ? (env["JARVIS_CUA_QUOTED_QUERY"] == "1"
                    ? "In Google Chrome in the background, search this local site for exactly \"copper lantern\", then open the Copper Lantern Guide result."
                    : "In Google Chrome in the background, search this local site for copper lantern, then open the Copper Lantern Guide result.")
                : generatedDraft
                ? "In Google Chrome in the background, write an original five-word friendly greeting in the verification value field. Leave it as a draft; do not submit."
                : "In Google Chrome in the background, type copper lantern in the verification value field and submit this local test form."
            let result = try await agent.run(goal: goal, context: "This is an isolated disposable local form. The target window is already supplied. No real recipient or purchase exists.", progress: { print("Browser fixture step:", $0) })
            let (data, _) = try await URLSession.shared.data(from: URL(string: url + "state")!)
            let state = try JSONDecoder().decode(JSONValue.self, from: data)
            if !repeatedScrolling { XCTAssertTrue(mutations.contains("browser_type")) }
            if repeatedScrolling {
                XCTAssertEqual(mutations.filter { $0 == "browser_pointer" }.count, 2)
                XCTAssertEqual(state["scroll_positions"], .array([.number(500), .number(1000)]))
            } else if searchNavigation {
                XCTAssertEqual(state["query"], .string("copper lantern"))
                XCTAssertEqual(state["destination_query"], .string("copper lantern"))
                let page = try await target.observe(call: call)
                XCTAssertEqual(page["target_id"], target.target)
                XCTAssertEqual(page["tab_id"], target.tab)
                let destination = try XCTUnwrap(page["page"]?["url"]?.string)
                let components = try XCTUnwrap(URLComponents(string: destination))
                XCTAssertEqual(components.host, "127.0.0.1")
                XCTAssertEqual(components.port, URLComponents(string: url)?.port)
                XCTAssertEqual(components.path, "/destination")
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "copper lantern")
            } else if generatedDraft {
                XCTAssertEqual(state["submitted"], .null, "Drafting must not submit")
                XCTAssertFalse(mutations.contains("browser_click"))
                let page = try await target.observe(call: call)
                let field = (page["refs"]?.array ?? []).first { $0["role"] == .string("textbox") && $0["name"] == .string("verification value") }
                let text = try XCTUnwrap(field?["value"]?.string)
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertEqual(text.split(whereSeparator: \.isWhitespace).count, 5)
                print("Generated draft observed; word count:", text.split(whereSeparator: \.isWhitespace).count)
            } else {
                XCTAssertEqual(state["submitted"], .string("copper lantern"))
                XCTAssertTrue(mutations.contains("browser_click"))
            }
            print("Browser fixture result:", result)
        } catch {
            _ = try? await connection.call("end_session", arguments: ["session": .string(label)])
            await connection.close()
            if let ownedPID { NSRunningApplication(processIdentifier: pid_t(ownedPID))?.terminate() }
            throw error
        }
        _ = try? await connection.call("end_session", arguments: ["session": .string(label)])
        await connection.close()
        if let ownedPID { NSRunningApplication(processIdentifier: pid_t(ownedPID))?.terminate() }
    }
}

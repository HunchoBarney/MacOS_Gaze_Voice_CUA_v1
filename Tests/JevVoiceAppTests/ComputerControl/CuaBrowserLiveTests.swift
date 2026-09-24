import AppKit
import CryptoKit
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
    func testDirectNavigationCandidateThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_SEARCH_TEST"] == "1" else { throw XCTSkip("Opt-in disposable local direct navigation") }
        try await runFixture(generatedDraft: false, directNavigation: true)
    }
    func testFileUploadCandidateThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_UPLOAD_TEST"] == "1" else { throw XCTSkip("Opt-in disposable loopback file upload") }
        try await runFixture(generatedDraft: false, uploadFile: true)
    }
    func testJavaScriptDialogCandidateThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_DIALOG_TEST"] == "1" else { throw XCTSkip("Opt-in disposable JavaScript dialog resolution") }
        try await runFixture(generatedDraft: false, dialogResolution: true)
    }
    func testRepeatedScrollThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_SEARCH_TEST"] == "1" else { throw XCTSkip("Opt-in disposable repeated scrolling") }
        try await runFixture(generatedDraft: false, repeatedScrolling: true)
    }
    func testUnverifiableScrollStopsAfterOneEffectOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_SEARCH_TEST"] == "1" else { throw XCTSkip("Opt-in pinned-runtime scroll refusal proof") }
        try await runFixture(generatedDraft: false, repeatedScrolling: true, expectUnverifiableScroll: true)
    }
    func testPointerHoverCandidateThroughAgentOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_POINTER_TEST"] == "1" else { throw XCTSkip("Opt-in disposable browser pointer hover") }
        try await runFixture(generatedDraft: false, pointerHover: true)
    }
    func testGeneratedDraftDoesNotSubmitOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_GENERATION_TEST"] == "1" else { throw XCTSkip("Opt-in configured provider fixture") }
        try await runFixture(generatedDraft: true)
    }
    private func runFixture(generatedDraft: Bool, searchNavigation: Bool = false, repeatedScrolling: Bool = false,
                            expectUnverifiableScroll: Bool = false,
                            directNavigation: Bool = false, uploadFile: Bool = false, dialogResolution: Bool = false,
                            pointerHover: Bool = false) async throws {
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
            let startURL = repeatedScrolling ? url + "scrolling" : uploadFile ? url + "upload" : dialogResolution ? url + "dialog" : pointerHover ? url + "pointer" : searchNavigation ? url + "?fixture=prefilled" : url
            if dialogResolution {
                // Match the recorded Driver activation watchdog settlement used
                // by the native disposable-window proof.
                try await Task.sleep(for: .seconds(9))
                let raised = try await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(window))])
                XCTAssertEqual(raised["activated"], .bool(true))
                _ = try await target.inspectDialog(call: call)
            }
            _ = try await call("browser_navigate", ["target_id": target.target, "tab_id": target.tab, "url": .string(startURL)])
            if pointerHover {
                var observed = try await target.observe(call: call)
                for _ in 0..<30 where observed["page"]?["url"] != .string(startURL) {
                    try await Task.sleep(for: .milliseconds(100))
                    observed = try await target.observe(call: call)
                }
            }
            if dialogResolution {
                var dialog = try await target.inspectDialog(call: call)
                for _ in 0..<30 where dialog["present"] != .bool(true) {
                    try await Task.sleep(for: .milliseconds(100))
                    dialog = try await target.inspectDialog(call: call)
                }
                XCTAssertEqual(dialog["present"], .bool(true), "The disposable foreground page must expose its JavaScript confirmation.")
            }
            var mutations: [String] = []
            var mutationArguments: [(String, [String: JSONValue])] = []
            var agentTargetID: JSONValue?
            var agentTabID: JSONValue?
            let uploadedFile = uploadFile ? FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis-upload-\(UUID().uuidString).txt") : nil
            let uploadContent = Data("disposable Jarvis upload fixture".utf8)
            if let uploadedFile { try uploadContent.write(to: uploadedFile) }
            defer { if let uploadedFile { try? FileManager.default.removeItem(at: uploadedFile) } }
            let agent = CuaTaskAgent(call: { tool, arguments in
                // This supporting integration test constrains inventory to its own isolated process.
                if tool == "list_apps" || tool == "get_accessibility_tree" {
                    let live = try await call("get_accessibility_tree", [:])
                    let own = (live["apps"]?.array ?? []).filter { $0["pid"]?.integer == pid }
                    return .object(["apps": .array(own)])
                }
                if !["get_window_state", "get_browser_state", "list_windows"].contains(tool),
                   !(tool == "browser_dialog" && arguments["action"] == .string("inspect")) {
                    mutations.append(tool)
                    mutationArguments.append((tool, arguments))
                }
                let result = try await call(tool, arguments)
                if tool == "get_browser_state", arguments["target_id"] == nil {
                    let tabs = result["tabs"]?.array ?? []
                    let active = tabs.filter { $0["active"] == .bool(true) }
                    if tabs.count == 1 || active.count == 1 {
                        agentTargetID = result["target_id"]
                        agentTabID = (tabs.count == 1 ? tabs.first : active.first)?["tab_id"]
                    }
                }
                return result
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
               approve: uploadFile || dialogResolution ? { description in
                   print("Authorized disposable browser fixture action:", description)
                   return true
               } : nil,
               payload: { request, purpose in try await JevSpeechIntent(client: JevClient(apiKey: key)).textPayload(request: request, purpose: purpose) },
               actionSurface: directNavigation || uploadFile || dialogResolution || pointerHover ? .candidate : .production)
            let goal = repeatedScrolling
                ? "In Google Chrome in the background, scroll the Scrollable guide down once, then scroll it down one more time. Make exactly two downward scroll actions."
                : directNavigation
                ? "In Google Chrome in the background, open \"\(url)destination?q=copper%20lantern\"."
                : pointerHover
                ? "In Google Chrome in the background, hover over the Pointer target link without clicking."
                : uploadFile
                ? "Upload the file \"\(uploadedFile!.path)\" in Google Chrome in the background."
                : dialogResolution
                ? "In Google Chrome in the background, accept the current JavaScript dialog."
                : searchNavigation
                ? (env["JARVIS_CUA_QUOTED_QUERY"] == "1"
                    ? "In Google Chrome in the background, finish the prefilled query by typing exactly \" lantern\", then search this local site and open the Copper Lantern Guide result."
                    : "In Google Chrome in the background, search this local site for copper lantern, then open the Copper Lantern Guide result.")
                : generatedDraft
                ? "In Google Chrome in the background, write an original five-word friendly greeting in the verification value field. Leave it as a draft; do not submit."
                : "In Google Chrome in the background, type copper lantern in the verification value field and submit this local test form."
            let taskResult: String?
            let taskFailure: Error?
            do {
                taskResult = try await agent.run(goal: goal, context: "This is an isolated disposable local form. The target window is already supplied. No real recipient or purchase exists.", progress: { print("Browser fixture step:", $0) })
                taskFailure = nil
            } catch {
                taskResult = nil
                taskFailure = error
            }
            let (data, _) = try await URLSession.shared.data(from: URL(string: url + "state")!)
            let state = try JSONDecoder().decode(JSONValue.self, from: data)
            if expectUnverifiableScroll {
                guard let taskFailure else { throw DriverConnectionError.refused("The pinned Driver unexpectedly completed a repeated-scroll task without a confirmed scroll outcome.") }
                XCTAssertTrue(taskFailure.localizedDescription.contains("Cua could not confirm the result of"), taskFailure.localizedDescription)
                XCTAssertTrue(taskFailure.localizedDescription.contains("no further action was dispatched"), taskFailure.localizedDescription)
                XCTAssertEqual(mutations, ["browser_pointer"], "No mutation may follow the unconfirmed first scroll")
                XCTAssertEqual(state["scroll_positions"], .array([.number(500)]), "The independent fixture must observe only the first 500 px effect")
                print("Pinned scroll guard evidence:", taskFailure.localizedDescription, "mutations:", mutations, "positions:", state["scroll_positions"] ?? .null)
            } else {
                if let taskFailure { throw taskFailure }
                guard let result = taskResult else { throw DriverConnectionError.malformed }
                if !repeatedScrolling && !directNavigation && !uploadFile && !dialogResolution && !pointerHover { XCTAssertTrue(mutations.contains("browser_type")) }
                if dialogResolution {
                    XCTAssertEqual(mutations.filter { $0 == "browser_click" }.count, 0)
                    XCTAssertEqual(mutations.filter { $0 == "browser_dialog" }.count, 1)
                    XCTAssertEqual(state["dialog_decision"], .string("accepted"))
                } else if repeatedScrolling {
                    XCTAssertEqual(mutations.filter { $0 == "browser_pointer" }.count, 2)
                    XCTAssertEqual(state["scroll_positions"], .array([.number(500), .number(1000)]))
                } else if directNavigation {
                    XCTAssertEqual(mutations.filter { $0 == "browser_navigate" }.count, 1)
                    XCTAssertEqual(state["destination_query"], .string("copper lantern"))
                    let page = try await target.observe(call: call)
                    let destination = try XCTUnwrap(page["page"]?["url"]?.string)
                    XCTAssertEqual(destination, url + "destination?q=copper%20lantern")
                } else if uploadFile {
                    XCTAssertTrue(mutations.contains("browser_set_input_files"))
                    var uploadState = state["upload"]
                    for _ in 0..<20 where uploadState == nil || uploadState == .null {
                        try await Task.sleep(for: .milliseconds(100))
                        let (freshData, _) = try await URLSession.shared.data(from: URL(string: url + "state")!)
                        uploadState = try JSONDecoder().decode(JSONValue.self, from: freshData)["upload"]
                    }
                    let upload = try XCTUnwrap(uploadState?.object)
                    XCTAssertEqual(upload["name"], .string(uploadedFile?.lastPathComponent ?? ""))
                    XCTAssertEqual(upload["size"], .number(Double(uploadContent.count)))
                    XCTAssertEqual(upload["sha256"], .string(SHA256.hash(data: uploadContent).map { String(format: "%02x", $0) }.joined()))
                } else if pointerHover {
                    XCTAssertEqual(mutations.filter { $0 == "browser_pointer" }.count, 1)
                    let dispatch = try XCTUnwrap(mutationArguments.first { $0.0 == "browser_pointer" }?.1)
                    XCTAssertNotNil(agentTargetID)
                    XCTAssertNotNil(agentTabID)
                    XCTAssertEqual(dispatch["target_id"], agentTargetID)
                    XCTAssertEqual(dispatch["tab_id"], agentTabID)
                    XCTAssertEqual(dispatch["action"], .string("hover"))
                    XCTAssertEqual(dispatch["input_route"], .string("dom_event"))
                    XCTAssertNotNil(dispatch["ref"]?.string)
                    XCTAssertEqual(state["pointer_events"], .array([.string("mouseenter")]))
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
            }
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

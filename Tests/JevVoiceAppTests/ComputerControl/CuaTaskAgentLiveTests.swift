import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaTaskAgentLiveTests: XCTestCase {
    func testEmbeddedAppCatalogOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_APP_READ"] == "1" else { throw XCTSkip("Opt-in read-only cross-app Driver observations") }
        let connection = CuaConnection()
        try await connection.connect()
        let label = "Jarvis embedded observation \(UUID().uuidString.prefix(8))"
        do {
            _ = try await connection.call("start_session", arguments: ["session": .string(label)])
            let call: CuaTaskAgent.Call = { name, args in
                try await connection.call(name, arguments: args.merging(["session": .string(label)]) { _, b in b })
            }
            let apps = try await call("get_accessibility_tree", [:])
            for bundle in ["com.spotify.client", "com.apple.calculator", "com.apple.TextEdit"] {
                let pid = try XCTUnwrap(apps["apps"]?.array?.first { $0["bundle_id"] == .string(bundle) }?["pid"]?.integer)
                let windows = try await call("list_windows", ["pid": .number(Double(pid))])
                let titled = (windows["windows"]?.array ?? []).filter { !($0["title"]?.string ?? "").isEmpty }
                let visible = titled.filter { $0["is_on_screen"] == .bool(true) }
                let candidates = visible.isEmpty ? titled : visible
                // This observation fixture targets the largest document surface, not a
                // tiny tooltip. It never chooses a content destination for the product.
                func area(_ window: JSONValue) -> Double {
                    guard case .number(let width) = window["bounds"]?["width"],
                          case .number(let height) = window["bounds"]?["height"] else { return 0 }
                    return width * height
                }
                let window = try XCTUnwrap(candidates.max { area($0) < area($1) }?["window_id"]?.integer)
                if ProcessInfo.processInfo.environment["JARVIS_CUA_APP_FOREGROUND"] == "1" {
                    let raised = try await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(window))])
                    XCTAssertEqual(raised["activated"], .bool(true))
                    XCTAssertEqual(raised["exact_window_effect"]?["verified"], .bool(true))
                }
                let browser = try await CuaBrowserTarget.discover(pid: pid, window: window, call: call)
                XCTAssertNil(browser)
                let arguments: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "include_screenshot": .bool(false), "max_elements": .number(220)]
                var snapshot = try await call("get_window_state", arguments)
                if snapshot["elements"]?.array?.isEmpty == true { snapshot = try await call("get_window_state", arguments) }
                let elements = snapshot["elements"]?.array ?? []
                print("Observation scope:", bundle, "window", window, "candidate count", candidates.count,
                      "degraded", snapshot["degraded_reason"] ?? .null, "complete", snapshot["elements_complete"] ?? .null)
                let actions = CuaActionCatalog.native(elements: elements, pid: pid, window: window, includeEmbeddedWebControls: browser == nil)
                print("Observed control coverage:", bundle, "elements:", elements.count, "actions:", actions.count)
                XCTAssertFalse(actions.isEmpty, bundle)
                if bundle == "com.spotify.client" {
                    XCTAssertTrue(actions.contains { $0.tool == "click" && $0.description.contains("Search") })
                }
            }
            _ = try await call("end_session", [:])
        } catch { await connection.close(); throw error }
        await connection.close()
    }
    func testUnspecifiedTargetDoesNotBorrowPriorAppOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_AGENT_TEST"] == "1",
              let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] else { throw XCTSkip("Opt-in live Jev target judgment; no OS mutation") }
        for request in ["Open something.", "Can you open an app?", "Open the thing."] {
            var furtherCalls = 0
            let agent = CuaTaskAgent(call: { tool, _ in
                if tool == "list_apps" { return .object(["apps": .array([
                    .object(["name": .string("Calculator"), "bundle_id": .string("com.apple.calculator")]),
                    .object(["name": .string("TextEdit"), "bundle_id": .string("com.apple.TextEdit")])])]) }
                furtherCalls += 1
                throw DriverConnectionError.refused("Unexpected app selection")
            }, judge: { state, questions in
                try await JevClient(apiKey: key).systemOne(state: state, questions: questions).response.answers
            })
            do {
                _ = try await agent.run(goal: request, context: "Calculator", progress: { _ in })
                XCTFail("Unspecified target must ask for clarification")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Which app"), error.localizedDescription)
            }
            XCTAssertEqual(furtherCalls, 0, request)
        }
    }
    func testNativeFixtureOptIn() async throws { try await fixture(createDocument: false) }
    func testNewDocumentFixtureOptIn() async throws { try await fixture(createDocument: true) }

    private func fixture(createDocument: Bool) async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_AGENT_TEST"] == "1" else {
            throw XCTSkip("Opt-in real Cua/Jev native fixture check")
        }
        let key = try CuaLiveCredential.jev()
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let label = "Jarvis agent fixture \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(label)])
        do {
            let permissions = try await connection.call("check_permissions", arguments: ["prompt": .bool(false), "session": .string(label)])
            print("Native fixture Driver permissions:", permissions["accessibility"]?.bool ?? false, permissions["screen_recording"]?.bool ?? false)
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis-Agent-\(UUID()).txt")
            let originalText = createDocument ? "Existing disposable document must remain unchanged." : ""
            try originalText.write(to: fixture, atomically: true, encoding: .utf8)
            let launched = try await connection.call("launch_app", arguments: ["bundle_id": .string("com.apple.TextEdit"), "urls": .array([.string(fixture.path)]), "session": .string(label)])
            let pid = try XCTUnwrap(launched["pid"]?.integer)
            var matches: [JSONValue] = []
            for _ in 0..<50 {
                let listed = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(label)])
                matches = (listed["windows"]?.array ?? []).filter { $0["title"]?.string?.contains(fixture.lastPathComponent) == true }
                if matches.count == 1 { break }
                guard matches.isEmpty else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard matches.count == 1 else { throw DriverConnectionError.refused("Disposable native fixture window is ambiguous.") }
            let window = try XCTUnwrap(matches.first?["window_id"]?.integer)
            if ProcessInfo.processInfo.environment["JARVIS_CUA_SETTLED_FIXTURE"] == "1" {
                // Controlled baseline isolation only: pinned launch_app suppresses
                // activation for eight seconds after returning from a URL launch.
                // This does not establish production launch→foreground correctness.
                try await Task.sleep(for: .seconds(9))
            }
            if createDocument {
                var fields: [JSONValue] = []
                var lastInitial: JSONValue?
                for _ in 0..<150 {
                    let initial = try await connection.call("get_window_state", arguments: ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "include_screenshot": .bool(false), "session": .string(label)])
                    lastInitial = initial
                    fields = (initial["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
                    if fields.count == 1, fields[0]["value"] == .string(originalText) { break }
                    let currentValue = fields.first?["value"]?.string
                    guard currentValue == nil || currentValue?.isEmpty == true else {
                        throw DriverConnectionError.refused("The disposable source contains unexpected content; the agent will not run.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard fields.count == 1, fields[0]["value"] == .string(originalText) else {
                    let lengths = fields.map { $0["value"]?.string?.count ?? -1 }
                    let elements = lastInitial?["elements"]?.array ?? []
                    let roleCounts = Dictionary(grouping: elements.compactMap { $0["role"]?.string }, by: { $0 })
                        .mapValues(\.count)
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value)" }
                    let windowSummary = matches.first.map {
                        let onScreen = $0["is_on_screen"]?.bool.map { String($0) } ?? "<missing>"
                        return "id=\($0["window_id"]?.integer ?? -1), title=\($0["title"]?.string ?? "<missing>"), onScreen=\(onScreen)"
                    } ?? "<missing>"
                    let stateKeys = lastInitial?.object.map { Array($0.keys).sorted() } ?? []
                    let degraded = lastInitial?["degraded_reason"]?.string ?? "<none>"
                    let complete = lastInitial?["elements_complete"]?.bool.map { String($0) } ?? "<missing>"
                    let safeElements = elements.prefix(30).map { element -> String in
                        let role = element["role"]?.string ?? "?"
                        let labelLength = element["label"]?.string?.count ?? -1
                        let identifierLength = element["identifier"]?.string?.count ?? -1
                        let valueLength = element["value"]?.string?.count ?? -1
                        return "\(role){labelLength:\(labelLength),identifierLength:\(identifierLength),valueLength:\(valueLength)}"
                    }
                    print("Native fixture initial-state diagnostic:",
                          "window=\(windowSummary)", "stateKeys=\(stateKeys)",
                          "degraded=\(degraded)", "complete=\(complete)",
                          "elementCount=\(elements.count)", "roles=\(roleCounts)",
                          "safeElements=\(safeElements)")
                    throw DriverConnectionError.refused("The disposable source did not reach the exact initial state; the agent will not run (fields: \(fields.count), value lengths: \(lengths), element count: \(elements.count)).")
                }
            }
            let client = JevClient(apiKey: key)
            let agent = CuaTaskAgent(call: { tool, args in
                var beforeActivation: [JSONValue]?
                let readArgs = args.merging(["include_screenshot": .bool(false), "session": .string(label)]) { _, b in b }
                if tool == "bring_to_front" {
                    let before = try await connection.call("get_window_state", arguments: readArgs)
                    beforeActivation = (before["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }.map { $0["value"] ?? .null }
                }
                let result: JSONValue
                do {
                    result = try await connection.call(tool, arguments: args.merging(["session": .string(label)]) { _, b in b })
                } catch let outcome as CuaUncertainOutcome {
                    if tool == "bring_to_front" { print("Native fixture foreground outcome:", outcome.result) }
                    throw outcome
                }
                if let beforeActivation {
                    let after = try await connection.call("get_window_state", arguments: readArgs)
                    let afterValues = (after["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }.map { $0["value"] ?? .null }
                    guard afterValues == beforeActivation else {
                        throw DriverConnectionError.refused("Text changed across the exact-window activation boundary; the fixture stopped before further actions.")
                    }
                }
                if tool == "get_window_state" {
                    let fields = (result["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
                    print("Fixture observation window:", args["window_id"]?.integer ?? -1, "body lengths:", fields.map { $0["value"]?.string?.count ?? -1 }, "expected text present:", fields.contains { $0["value"]?.string?.lowercased().contains("copper lantern beside the window") == true })
                }
                return result
            }, judge: { state, questions in
                let answers = try await client.systemOne(state: state, questions: questions).response.answers
                print("Native fixture judgments:", answers)
                return answers
            }, windowID: window, allowConfirmedRepetition: ProcessInfo.processInfo.environment["JARVIS_CUA_SIMPLIFIED"] == "1", approve: { operation in
                print("Authorized disposable-fixture participation:", operation)
                return true
            }, payload: { request, purpose in
                try await JevSpeechIntent(client: client).textPayload(request: request, purpose: purpose)
            })
            let start = ContinuousClock.now
            _ = try await agent.run(goal: createDocument ? "In TextEdit in the background, create a new document and insert exactly \"copper lantern beside the window\"." : "In TextEdit, please type copper lantern beside the window into the blank document.", context: "The provided window is the existing starting document. If asked to create a new document, do not reuse this one. It is a disposable fixture.", progress: { print("Fixture step:", $0) })
            let resultWindow = try XCTUnwrap(agent.windowID)
            if createDocument { XCTAssertNotEqual(resultWindow, window, "The request requires a new document, not an edit to the fixture") }
            let observed = try await connection.call("get_window_state", arguments: ["pid": .number(Double(pid)), "window_id": .number(Double(resultWindow)), "include_screenshot": .bool(false), "session": .string(label)])
            let bodies = (observed["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
            XCTAssertEqual(bodies.first?["value"]?.string, "copper lantern beside the window")
            if createDocument {
                let original = try await connection.call("get_window_state", arguments: ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "include_screenshot": .bool(false), "session": .string(label)])
                let originalBodies = (original["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
                XCTAssertEqual(originalBodies.count, 1)
                XCTAssertEqual(originalBodies.first?["value"], .string(originalText), "Creating a new document must not edit the starting fixture")
            }
            print("Native agent fixture duration:", start.duration(to: .now))
        } catch {
            _ = try? await connection.call("end_session", arguments: ["session": .string(label)])
            await connection.close()
            throw error
        }
        _ = try await connection.call("end_session", arguments: ["session": .string(label)])
        await connection.close()
    }
}

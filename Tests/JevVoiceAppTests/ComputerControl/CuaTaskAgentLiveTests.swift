import XCTest
import JevVoiceCore
@testable import JevVoice

/// Opt-in live checks against the real Cua driver + real models. Under the
/// split architecture these exercise the two production seams directly:
/// `CompanionBrain` (one decision per utterance) and `CuaAgentLoop.drive`
/// (Jev-picked steps). The fixture invariants are unchanged: disposable
/// window, observed readbacks, no mutation after cancellation.
@MainActor
final class CuaTaskAgentLiveTests: XCTestCase {

    /// An unspecified target must surface a clarify decision — never a guessed
    /// app. Live provider, zero driver calls.
    func testUnspecifiedTargetDoesNotBorrowPriorAppOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_AGENT_TEST"] == "1" else {
            throw XCTSkip("Opt-in live planner clarify check; no OS mutation")
        }
        let brain = CompanionBrain(settings: .shared)
        for request in ["Open something.", "Can you open an app?", "Open the thing."] {
            let decision: PlannerDecision
            do {
                decision = try await brain.decide(utterance: request, context: PlannerContext())
            } catch {
                throw XCTSkip("Text provider unavailable for live clarify check: \(error.localizedDescription)")
            }
            guard case .clarify = decision else {
                XCTFail("Unspecified target must ask for clarification, got \(decision)")
                continue
            }
        }
    }

    func testNativeFixtureOptIn() async throws { try await fixture(createDocument: false) }
    func testNewDocumentFixtureOptIn() async throws { try await fixture(createDocument: true) }
    func testPostDispatchTimeoutInspectsNativeTargetOptIn() async throws {
        try await fixture(createDocument: true, simulatePostDispatchTimeout: true)
    }
    func testCancellationAfterNativeDispatchLeavesOneEffectOptIn() async throws {
        try await fixture(createDocument: true, cancelAfterDispatch: true)
    }

    private func fixture(createDocument: Bool, simulatePostDispatchTimeout: Bool = false,
                         cancelAfterDispatch: Bool = false) async throws {
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
            var timedOutDispatches = 0
            var postTimeoutReadbacks = 0
            var textDispatches = 0
            var lateMutations = 0
            let loop = CuaAgentLoop(call: { tool, args in
                if cancelAfterDispatch, textDispatches > 0,
                   !["list_apps", "get_accessibility_tree", "list_windows", "get_window_state", "get_browser_state", "parse_visual_regions"].contains(tool) {
                    lateMutations += 1
                }
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
                    if timedOutDispatches > 0 { postTimeoutReadbacks += 1 }
                    let fields = (result["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
                    print("Fixture observation window:", args["window_id"]?.integer ?? -1, "body lengths:", fields.map { $0["value"]?.string?.count ?? -1 }, "expected text present:", fields.contains { $0["value"]?.string?.lowercased().contains("copper lantern beside the window") == true })
                }
                if tool == "type_text", simulatePostDispatchTimeout {
                    // Cua has already returned from one real insertion. Simulate
                    // losing that response to the host after the effect.
                    timedOutDispatches += 1
                    throw DriverConnectionError.timedOut
                }
                if tool == "type_text", cancelAfterDispatch {
                    textDispatches += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return result
            }, judge: { state, questions in
                let answers = try await client.systemOne(state: state, questions: questions).response.answers
                print("Native fixture judgments:", answers)
                return answers
            }, approve: { operation in
                print("Authorized disposable-fixture participation:", operation)
                return true
            }, progress: { print("Fixture step:", $0) })
            let start = ContinuousClock.now
            let goal = createDocument
                ? "In TextEdit, create a new document and insert exactly \"copper lantern beside the window\". The pinned window is the existing starting document — do not reuse it; it is a disposable fixture."
                : "In TextEdit, please type copper lantern beside the window into the blank document."
            let operation = Task {
                try await loop.drive(DriveTask(goal: goal, application: "com.apple.TextEdit",
                                               pid: pid, windowID: window,
                                               values: ["literal_text": "copper lantern beside the window"]))
            }
            var result: DriveResult?
            var statusLine = ""
            do {
                result = try await operation.value
                statusLine = result.map { "\($0.status)" } ?? ""
                if case .done = result?.status {} else if let r = result {
                    statusLine = r.history.last ?? "\(r.status)"
                    throw DriverConnectionError.refused(statusLine)
                }
                XCTAssertFalse(simulatePostDispatchTimeout || cancelAfterDispatch, "A stopped or uncertain task must not report completion")
            } catch {
                if simulatePostDispatchTimeout {
                    XCTAssertTrue(error.localizedDescription.contains("uncertain"), error.localizedDescription)
                } else if cancelAfterDispatch {
                    XCTAssertTrue(error is CancellationError, error.localizedDescription)
                } else { throw error }
            }
            if simulatePostDispatchTimeout {
                XCTAssertEqual(timedOutDispatches, 1, "The real insertion must not be repeated")
                XCTAssertEqual(postTimeoutReadbacks, 1, "The pinned target must be read once before reporting uncertainty")
            }
            if cancelAfterDispatch {
                XCTAssertEqual(textDispatches, 1, "The fixture needs exactly one real insertion")
                XCTAssertEqual(lateMutations, 0, "No mutation may follow acknowledged cancellation")
            }
            let resultWindow = try XCTUnwrap(result?.windowID ?? loop.currentWindowID)
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

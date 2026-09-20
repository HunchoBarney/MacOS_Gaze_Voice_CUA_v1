import XCTest
import JevVoiceCore
@testable import JevVoice

final class CuaPerceptionLiveTests: XCTestCase {
    @MainActor
    func testTaskAgentFindsAndExecutesDrawnControlOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_VISUAL_AGENT_TEST"] == "1" else {
            throw XCTSkip("Requires selected local Driver, Jev key and fresh disposable visual fixture")
        }
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? KeychainAPIKeyStore().read())
        let connection = CuaConnection()
        try await connection.connect()
        let session = "Jarvis visual agent \(UUID().uuidString.prefix(8))"
        let call: CuaTaskAgent.Call = { name, args in
            try await connection.call(name, arguments: args.merging(["session": .string(session)]) { _, b in b })
        }
        do {
            _ = try await call("start_session", [:])
            let launch = try await call("launch_app", ["bundle_id": .string("dev.jarvis.perception-fixture")])
            let pid = try XCTUnwrap(launch["pid"]?.integer)
            let before = try await call("list_windows", ["pid": .number(Double(pid))])
            let windows = before["windows"]?.array?.filter { $0["title"] == .string("Jarvis Visual Fixture — Ready") } ?? []
            let window = try XCTUnwrap(windows.count == 1 ? windows.first?["window_id"]?.integer : nil)
            var visualInspections = 0, clicks = 0
            let agent = CuaTaskAgent(call: { name, args in
                if name == "parse_visual_regions" { visualInspections += 1 }
                if name == "click" { clicks += 1 }
                return try await call(name, args)
            }, judge: { state, questions in
                let answers = try await JevClient(apiKey: key).systemOne(state: state, questions: questions).response.answers
                print("Visual agent decisions:", answers.mapValues { answer in
                    if case let .choice(choice, confidence, _) = answer { return "\(choice) confidence=\(confidence)" }
                    return "non-choice"
                }, "window titles:", state["windows"]?.array?.compactMap { $0["title"]?.string } ?? [])
                return answers
            }, windowID: window)
            let started = ContinuousClock.now
            _ = try await agent.run(goal: "In Jarvis Visual Fixture, activate the drawn Apply button once. Keep it in the background.", context: "", progress: { print("Visual agent:", $0) })
            let after = try await call("list_windows", ["pid": .number(Double(pid))])
            XCTAssertEqual(after["windows"]?.array?.first { $0["window_id"]?.integer == window }?["title"], .string("Jarvis Visual Fixture — Applied 1"))
            XCTAssertGreaterThan(visualInspections, 0)
            XCTAssertEqual(clicks, 1)
            print("Observed visual-agent total:", started.duration(to: .now))
        } catch {
            _ = try? await call("end_session", [:]); await connection.close(); throw error
        }
        _ = try? await call("end_session", [:]); await connection.close()
    }

    func testDrawnNativeControlAndMovedCaptureOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_PERCEPTION_TEST"] == "1" else {
            throw XCTSkip("Requires local source Driver, perception extension, OS grants and disposable PerceptionTarget.app")
        }
        // Credentials may require a user-controlled OS prompt. Resolve them
        // before creating a time-limited capture, never after observing a target.
        let jevKey: String?
        if ProcessInfo.processInfo.environment["JARVIS_CUA_PERCEPTION_JEV"] == "1" {
            jevKey = try XCTUnwrap(ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
                ?? KeychainAPIKeyStore().read())
        } else { jevKey = nil }
        let connection = CuaConnection(executable: URL(fileURLWithPath: "/Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local"))
        try await connection.connect()
        let label = "Jarvis visual fixture \(UUID().uuidString.prefix(8))"
        func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            try await connection.call(name, arguments: args.merging(["session": .string(label)]) { _, b in b })
        }
        do {
            let tools = try await connection.tools()
            XCTAssertTrue(tools.contains { $0["name"] == .string("parse_visual_regions") })
            let evidence = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JevVoice/verification")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(tools).write(to: evidence.appendingPathComponent("local-driver-tools.json"), options: .atomic)
            _ = try await call("start_session", [:])
            let launched = try await call("launch_app", ["bundle_id": .string("dev.jarvis.perception-fixture")])
            let pid = try XCTUnwrap(launched["pid"]?.integer)
            var candidates: [JSONValue] = []
            // LaunchServices may report the process before its first window exists.
            for _ in 0..<30 {
                let windows = try await call("list_windows", ["pid": .number(Double(pid))])
                candidates = (windows["windows"]?.array ?? []).filter { $0["title"] == .string("Jarvis Visual Fixture — Ready") }
                if !candidates.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(candidates.count, 1, "Use a fresh disposable fixture, not a prior mutated surface")
            let window = try XCTUnwrap(candidates.first?["window_id"]?.integer)
            let target: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window))]
            let captured = try await connection.callResult("get_window_state", arguments: target.merging([
                "session": .string(label), "include_screenshot": .bool(true), "include_accessibility_tree": .bool(false)
            ]) { _, b in b })
            XCTAssertTrue(captured.content.contains { $0["type"] == .string("image") })
            let capture = try XCTUnwrap(captured.structured["capture_id"]?.string)
            let started = ContinuousClock.now
            let parsed = try await call("parse_visual_regions", ["capture_id": .string(capture)])
            print("Fixture capture provenance:", parsed["capture"] as Any)
            let beforeClick = try await call("list_windows", ["pid": .number(Double(pid))])
            print("Fixture bounds before capture/click:", candidates.first?["bounds"] as Any,
                  beforeClick["windows"]?.array?.first { $0["window_id"]?.integer == window }?["bounds"] as Any)
            let observation = try CuaVisualObservation(parsed, captureID: capture, pid: pid, window: window)
            print("Observed native perception duration:", started.duration(to: .now), "regions:", observation.regions.count)
            let matching = observation.actions.filter { $0.description.lowercased().contains("text apply [region ") }
            XCTAssertEqual(matching.count, 1, "The rendered Apply label must be independently detected")
            var action = try XCTUnwrap(matching.first)
            if let key = jevKey {
                var criteria: [String: String?] = ["abstain": "No observed control satisfies the request."]
                for (index, candidate) in observation.actions.enumerated() { criteria["action_\(index)"] = candidate.description }
                let decision = try await JevClient(apiKey: key).systemOne(state: JSONValue.object([
                    "request": .string("Please activate the Apply control in this disposable window."),
                    "visual_regions": .array(observation.regions)
                ]), questions: ["action": .choice(instructions: "Select the observed control that satisfies the request; abstain if absent or ambiguous.", criteria: criteria)])
                guard case let .choice(id, confidence, probabilities) = decision.response.answers["action"],
                      confidence.isFinite, (0...1).contains(confidence),
                      probabilities.keys.allSatisfy({ criteria.keys.contains($0) }),
                      probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      let index = Int(id.replacingOccurrences(of: "action_", with: "")),
                      observation.actions.indices.contains(index) else {
                    throw DriverConnectionError.refused("Jev did not select a valid observed fixture control")
                }
                action = observation.actions[index]
                print("Fixture Jev selection latency ms:", decision.latencyMs)
            }
            _ = try await call(action.tool, action.arguments)
            let after = try await call("list_windows", ["pid": .number(Double(pid))])
            XCTAssertTrue((after["windows"]?.array ?? []).contains {
                $0["window_id"]?.integer == window && $0["title"] == .string("Jarvis Visual Fixture — Applied 1")
            }, "Tool success alone does not establish the click outcome")

            // A consumed capture only proves single-use admission. Use a fresh,
            // unconsumed capture to independently exercise the resize guard.
            let resizeCapture = try await call("get_window_state", target.merging([
                "include_screenshot": .bool(true), "include_accessibility_tree": .bool(false)
            ]) { _, b in b })
            let resizeCaptureID = try XCTUnwrap(resizeCapture["capture_id"]?.string)
            let warmStarted = ContinuousClock.now
            let warmParsed = try await call("parse_visual_regions", ["capture_id": .string(resizeCaptureID)])
            let warmObservation = try CuaVisualObservation(warmParsed, captureID: resizeCaptureID, pid: pid, window: window)
            XCTAssertEqual(warmObservation.actions.filter { $0.description.lowercased().contains("text apply [region ") }.count, 1)
            print("Second installed-Driver perception duration:", warmStarted.duration(to: .now), "regions:", warmObservation.regions.count)
            _ = try await call("set_window_frame", target.merging([
                "x": .number(180), "y": .number(180), "width": .number(520), "height": .number(390)
            ]) { _, b in b })
            do {
                _ = try await call(action.tool, action.arguments.merging(["capture_id": .string(resizeCaptureID)]) { _, b in b })
                XCTFail("A moved/resized capture must not authorize another click")
            } catch let error as DriverConnectionError {
                guard case .toolRefused(_, let code) = error else { throw error }
                XCTAssertEqual(code, "capture_frame_mismatch")
            }
            let final = try await call("list_windows", ["pid": .number(Double(pid))])
            XCTAssertTrue((final["windows"]?.array ?? []).contains {
                $0["window_id"]?.integer == window && $0["title"] == .string("Jarvis Visual Fixture — Applied 1")
            })
        } catch {
            _ = try? await call("end_session", [:])
            await connection.close()
            throw error
        }
        _ = try await call("end_session", [:])
        await connection.close()
    }
}

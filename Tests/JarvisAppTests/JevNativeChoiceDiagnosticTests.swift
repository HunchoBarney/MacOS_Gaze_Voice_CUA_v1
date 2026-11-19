import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

final class JevNativeChoiceDiagnosticTests: XCTestCase {
    enum DiagnosticError: Error {
        case unexpectedRead(String)
        case outputExists
    }

    actor Capture {
        struct Request: Encodable {
            let state: JSONValue
            let questions: [String: Question]
            let assets: [String: JevImageAsset]
        }

        let directory: URL
        let client: JevClient
        var requests = 0
        var actionRefinementRequests: [Int] = []

        init(directory: URL, client: JevClient) {
            self.directory = directory
            self.client = client
        }

        func write(_ name: String, data: Data) throws {
            let path = directory.appendingPathComponent(name).path
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw DiagnosticError.outputExists }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            try file.write(contentsOf: data)
        }

        func infer(_ state: JSONValue, _ questions: [String: Question],
                   assets: [String: JevImageAsset] = [:]) async throws
            -> (SystemOneResponse, Double) {
            let index = requests
            requests += 1
            if questions.keys.contains(where: { $0.hasPrefix("support_") }) {
                actionRefinementRequests.append(index)
            }
            try write("request-\(index).json",
                      data: JSONEncoder().encode(Request(state: state, questions: questions, assets: assets)))
            for (position, id) in assets.keys.sorted().enumerated() {
                guard let image = assets[id] else { continue }
                try write("request-\(index)-asset-\(position).\(image.format.rawValue)", data: image.data)
            }
            let result = try await client.systemOne(state: state, questions: questions, assets: assets)
            var answers: [String: JSONValue] = [:]
            for (key, answer) in result.response.answers {
                switch answer {
                case .noul(let value):
                    answers[key] = .object(["noul": .number(value)])
                case .choice(let choice, let confidence, let probabilities):
                    answers[key] = .object(["choice": .string(choice), "confidence": .number(confidence),
                        "probabilities": .object(probabilities.mapValues(JSONValue.number))])
                case .untrustedChoice(let choice, let probabilities):
                    answers[key] = .object(["choice": .string(choice),
                        "probabilities": .object(probabilities.mapValues(JSONValue.number))])
                case .box(let box, let confidence):
                    answers[key] = .object([
                        "box": .object(["top": .number(box.top), "bottom": .number(box.bottom),
                                        "left": .number(box.left), "right": .number(box.right)]),
                        "confidence": confidence.map(JSONValue.number) ?? .null,
                    ])
                default:
                    answers[key] = .null
                }
            }
            try write("answers-\(index).json", data: JSONEncoder().encode(JSONValue.object([
                "model": .string(result.response.model), "latency_ms": .number(result.latencyMs),
                "answers": .object(answers),
            ])))
            return result
        }

        func chosen(_ choice: DriveLoop.JevChoice?, name: String = "choice.json") throws {
            let value: JSONValue = choice.map { .object([
                "id": .string($0.id), "request_count": .number(Double($0.requestCount)),
                "applicability": $0.applicability.map(JSONValue.number) ?? .null,
                "probabilities": .object($0.probabilities.mapValues(JSONValue.number)),
                "proposed_action": $0.proposedActionID.map(JSONValue.string) ?? .null,
                "action_support": .object($0.actionSupport.mapValues(JSONValue.number)),
                "action_rejection": $0.actionRejection.map { .string($0.rawValue) } ?? .null,
            ]) } ?? .null
            try write(name, data: JSONEncoder().encode(value))
        }
    }

    actor CaptureBridge {
        let directory: URL
        let nonce: String
        let window: Jarvis.WindowRef
        let origin: CuaResultOrigin
        let tools: Set<String>
        var sequence = 0

        init(directory: URL, input: JSONValue, window: Jarvis.WindowRef) throws {
            self.directory = directory
            nonce = try XCTUnwrap(input["capture_bridge_nonce"]?.string)
            self.window = window
            origin = CuaResultOrigin(session: try XCTUnwrap(input["session"]?.string),
                daemonSocket: try XCTUnwrap(input["daemon_socket"]?.string),
                transport: UUID(), sessionEpoch: UUID())
            tools = CuaConnection.capturedElementTools(try XCTUnwrap(input["tools"]))
        }

        func image(_ name: String, _ arguments: [String: JSONValue]) async throws -> CuaToolResult {
            guard name == "get_window_state", arguments["pid"]?.integer == window.pid,
                  arguments["window_id"]?.integer == window.windowID,
                  arguments["session"]?.string == origin.session else {
                throw DiagnosticError.unexpectedRead("non-readonly bridge request")
            }
            sequence += 1
            try JSONSerialization.data(withJSONObject: ["nonce": nonce, "sequence": sequence])
                .write(to: directory.appendingPathComponent("capture-command.json"), options: .atomic)
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let data = try? Data(contentsOf: directory.appendingPathComponent("capture-reply.json")),
                   let response = try? JSONDecoder().decode(JSONValue.self, from: data),
                   response["nonce"] == .string(nonce), response["sequence"] == .number(Double(sequence)),
                   let raw = response["result"], let body = raw["structuredContent"],
                   body["pid"]?.integer == window.pid, body["window_id"]?.integer == window.windowID {
                    return CuaToolResult(structured: body,
                        content: try XCTUnwrap(raw["content"]?.array), origin: origin,
                        capturedElementTools: tools)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw DiagnosticError.unexpectedRead("fresh capture bridge deadline")
        }
    }

    func testVerifiedCalculatorReadOnlyDecisionCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_P4_REAL_APPS"] == "approved",
              let path = environment["JEV_CALCULATOR_CHOICE_INPUT"],
              let key = environment["JEV_NATIVE_CHOICE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in verified Calculator routing diagnostic")
        }
        let file = URL(fileURLWithPath: path)
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let pid = try XCTUnwrap(input["window"]?["pid"]?.integer)
        let windowID = try XCTUnwrap(input["window"]?["window_id"]?.integer)
        let expected = try XCTUnwrap(input["expected_display"]?.string)
        let goalExpected = input["expected_goal_result"]?.string ?? expected
        let goal = try XCTUnwrap(input["task"]?["goal"]?.string)
        guard input["qualification"] == .bool(false),
              ["5", "7"].contains(expected),
              ["5": "Calculate 2 plus 3 and show the result.",
               "7": "Calculate 3 plus 4 and show the result."][goalExpected] == goal,
              await MainActor.run(body: {
                  NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
              }) == "com.apple.calculator" else {
            return XCTFail("Verified Calculator scope required")
        }
        let window = Jarvis.WindowRef(pid: pid, windowID: windowID)
        let client = JevClient(apiKey: key, model: "jev-1.14.0")
        let capture = Capture(directory: file.deletingLastPathComponent(), client: client)
        func displayTraits() throws -> [JSONValue] {
            let application = AXUIElementCreateApplication(pid_t(pid))
            AXUIElementSetMessagingTimeout(application, 0.2)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement],
                  let root = windows.first(where: {
                      FocusedTextBinding.windowNumber($0).map(Int.init) == windowID
                  }) else {
                throw DiagnosticError.unexpectedRead("original native window missing")
            }
            var pending = [root]
            var visited = Set<AXUIElement>()
            var traits: [JSONValue] = []
            while let node = pending.popLast() {
                guard visited.count < 100 else { throw DiagnosticError.unexpectedRead("diagnostic node budget") }
                guard visited.insert(node).inserted else { continue }
                AXUIElementSetMessagingTimeout(node, 0.2)
                raw = nil
                if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &raw) == .success,
                   let children = raw as? [AXUIElement] { pending += children }
                raw = nil
                guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &raw) == .success,
                      raw as? String == "AXStaticText" else { continue }
                raw = nil
                guard AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &raw) == .success,
                      let raw else { continue }
                let value = (raw as? String) ?? (raw as? NSNumber)?.stringValue
                let normalized = value?.replacingOccurrences(of: "\u{200e}", with: "")
                    .replacingOccurrences(of: "\u{200f}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized == expected else { continue }
                var actions: CFArray?
                let actionStatus = AXUIElementCopyActionNames(node, &actions)
                var settable = DarwinBoolean(false)
                let valueStatus = AXUIElementIsAttributeSettable(
                    node, kAXValueAttribute as CFString, &settable)
                traits.append(.object([
                    "role": .string("AXStaticText"), "value_equals_expected": .bool(true),
                    "actions": .array((actions as? [String] ?? []).map(JSONValue.string)),
                    "action_status": .number(Double(actionStatus.rawValue)),
                    "value_settable": .bool(settable.boolValue),
                    "settable_status": .number(Double(valueStatus.rawValue)),
                ]))
            }
            return traits
        }
        func checkDisplay(_ phase: String) async throws {
            let observed = await NativeWindowObservation.live(window, .standard)
            let display = try XCTUnwrap(observed)
            try await capture.write("native-\(phase).json", data: JSONEncoder().encode(JSONValue.object([
                "complete": .bool(display.complete), "window_matches": .bool(display.window == window),
                "display_traits": .array(try displayTraits()),
                "observed_rows": .array(display.elements.map {
                    .object(["role": .string($0.role), "label": .string($0.label),
                             "value": $0.value.map(JSONValue.string) ?? .null])
                }),
            ])))
            let values = display.elements.filter {
                $0.role.lowercased().replacingOccurrences(of: "ax", with: "") == "statictext"
            }.compactMap { element -> String? in
                guard let value = element.value else { return nil }
                let text = value.replacingOccurrences(of: "\u{200e}", with: "")
                    .replacingOccurrences(of: "\u{200f}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil
                    ? text : nil
            }
            guard display.complete, display.window == window, values == [expected] else {
                throw DiagnosticError.unexpectedRead("Calculator native display changed")
            }
        }
        try await awaitReadOnlyFixture(window, expected: expected)
        try await checkDisplay("before")
        let driver = try XCTUnwrap(input["driver_reply"])
        guard driver["pid"]?.integer == pid, driver["window_id"]?.integer == windowID else {
            return XCTFail("Foreign driver snapshot")
        }
        let session = try XCTUnwrap(input["session"]?.string)
        let origin = CuaResultOrigin(session: session,
            daemonSocket: try XCTUnwrap(input["daemon_socket"]?.string),
            transport: UUID(), sessionEpoch: UUID())
        let tools = CuaConnection.capturedElementTools(try XCTUnwrap(input["tools"]))
        let choose = JevChooser.make(model: client.model) { state, questions in
            try await capture.infer(state, questions)
        }
        let loop = DriveLoop(call: { tool, arguments in
            switch tool {
            case "list_apps": return try XCTUnwrap(input["apps"])
            case "list_windows": return try XCTUnwrap(input["windows"])
            case "get_window_state":
                guard arguments["pid"]?.integer == pid,
                      arguments["window_id"]?.integer == windowID else {
                    throw DiagnosticError.unexpectedRead("foreign window")
                }
                return .object(["structuredContent": driver])
            default: throw DiagnosticError.unexpectedRead(tool)
            }
        }, choose: { state, candidates in
            try await capture.write("source-chooser-input.json", data: JSONEncoder().encode(JSONValue.object([
                "state": state,
                "candidates": .array(candidates.map {
                    .object(["id": .string($0.id), "description": .string($0.description)])
                }),
            ])))
            let choice = try await choose(state, candidates)
            try await capture.chosen(choice)
            if input["capture_existing_refinement"] == .bool(true) {
                let alreadyRefined = !(await capture.actionRefinementRequests).isEmpty
                let forcedStart = await capture.requests
                if !alreadyRefined {
                    var strict = try XCTUnwrap(state.object)
                    strict["_action_probability_floor"] = .number(1)
                    let diagnostic = try await choose(.object(strict), candidates)
                    try await capture.chosen(diagnostic, name: "choice-strict-diagnostic.json")
                }
                try await capture.write("refinement-diagnostic.json",
                    data: JSONEncoder().encode(JSONValue.object([
                        "qualification": .bool(false), "actuations": .number(0),
                        "normal_choice_returned": .bool(true),
                        "forced": .bool(!alreadyRefined),
                        "diagnostic_floor": alreadyRefined ? .null : .number(1),
                        "forced_primary_index": alreadyRefined ? .null : .number(Double(forcedStart)),
                        "refinement_request_indices": .array(
                            await capture.actionRefinementRequests.map { .number(Double($0)) }),
                    ])))
            }
            return choice
        }, ask: nil, granted: { false }, explicitConsent: false,
           scopedCall: { tool, arguments, expectedOrigin in
            guard tool == "get_window_state", expectedOrigin == nil,
                  arguments["pid"]?.integer == pid, arguments["window_id"]?.integer == windowID,
                  arguments["include_screenshot"] == .bool(true) else {
                throw DiagnosticError.unexpectedRead(tool)
            }
            return CuaToolResult(structured: driver,
                content: try XCTUnwrap(input["image_content"]?.array), origin: origin,
                capturedElementTools: tools)
        }, visualChoose: JevChooser.makeVisual(model: client.model) { state, questions, assets in
            try await capture.infer(state, questions, assets: assets)
        })
        let result = try await loop.preview(
            DriveTask(goal: goal, application: "com.apple.calculator", pid: pid, windowID: windowID,
                deny: try XCTUnwrap(input["deny"]?.array).map { try XCTUnwrap($0.string) }),
            session: session)
        let bridge = try CaptureBridge(directory: file.deletingLastPathComponent(), input: input, window: window)
        let source = DriveLoop.DriveCaptureSource(observe: { _, _ in
            throw DiagnosticError.unexpectedRead("unexpected non-image observation")
        }, window: window, session: session, observeImage: { name, arguments in
            try await bridge.image(name, arguments)
        })
        let task = TaskBrief(goal: goal, window: window)
        func observation(_ step: Int) async throws -> TaskObservation {
            let current = try await source.observation(of: window, depth: .standard, includeScreenshot: true)
            return TaskObservation(stepIndex: step, axSnapshot: current.snapshot,
                screenshot: current.image, task: task, history: [],
                budget: .init(roundsRemaining: nil, millisecondsRemaining: nil))
        }
        var original = try await observation(0)
        original.visualAnchor = original.screenshot?.frame
        let infer: JevChooser.VisualInfer = { state, questions, assets in
            try await capture.infer(state, questions, assets: assets)
        }
        let visual = try await JevVisualDecision.decide(original, model: client.model, infer: infer)
        var probe: [String: JSONValue] = ["qualification": .bool(false), "actuations": .number(0)]
        if case .act(let request) = visual, let proof = request.visualVerification {
            var fresh = try await observation(1)
            fresh.visualAnchor = original.visualAnchor
            probe["kind"] = .string(proof.kind.rawValue)
            probe["native_claim"] = .bool(proof.nativeOutcome != nil)
            probe["fresh_frame"] = .bool(proof.acceptsFresh(fresh))
            probe["fresh_native"] = .bool(proof.nativeOutcome?.freshValue(fresh) != nil)
            probe["original_rows"] = .number(Double(original.axSnapshot?.elements.count ?? 0))
            probe["fresh_rows"] = .number(Double(fresh.axSnapshot?.elements.count ?? 0))
            if let native = proof.nativeOutcome, let registry = NativeUIOutcomeRegistry(fresh) {
                let same = registry.records.values.filter { $0.identity == native.record.identity }
                probe["native_context_equal"] = .bool(registry.context == native.context)
                probe["same_cf_count"] = .number(Double(same.count))
                probe["same_bytes"] = .bool(same.contains {
                    Data($0.value.utf8) == Data(native.record.value.utf8)
                })
            }
            do {
                let verified = try await JevVisualDecision.verifyGoal(proof, observation: fresh,
                    model: client.model, infer: infer)
                probe["verified"] = .bool(verified != nil)
            } catch VisualGoalFailure.subjectUnverified {
                probe["subject_refused"] = .bool(true)
            }
        } else {
            probe["readonly_goal_claim"] = .bool(false)
        }
        try await capture.write("visual-diagnostic.json", data: JSONEncoder().encode(JSONValue.object(probe)))
        try await checkDisplay("after")
        let requests = await capture.requests
        XCTAssertGreaterThan(requests, 0)
        try await capture.write("diagnostic.json", data: JSONEncoder().encode(JSONValue.object([
            "qualification": .bool(false), "actuations": .number(0),
            "model_requests": .number(Double(requests)), "preview": .string(result),
            "native_display_unchanged": .bool(true),
            "history_kind": .string("production preview, not actuator-run history"),
        ])))
    }

    private func ownedReadOnlyScope(_ input: JSONValue, window: Jarvis.WindowRef) async throws -> Bool {
        let (bundle, executable) = await MainActor.run {
            let application = NSRunningApplication(processIdentifier: pid_t(window.pid))
            return (application?.bundleIdentifier, application?.executableURL)
        }
        guard let fixture = input["fixture"] else { return bundle == "com.apple.calculator" }
        let path = try XCTUnwrap(fixture["binary"]?.string)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        return bundle == "dev.jarvis.native-ui-outcome-fixture"
            && executable?.standardizedFileURL == url
            && fixture["binary_sha256"] == .string(hash)
    }

    func testPreparationCannotAuthorizeSubjectSwitchesThroughProductionCandidates() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JEV_NATIVE_VALIDITY_OUTPUT"],
              let key = environment["JEV_NATIVE_CHOICE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in source-factory subject-switch model validation")
        }
        let directory = URL(fileURLWithPath: path)
        let client = JevClient(apiKey: key, model: "jev-1.14.0")
        for (kind, goal, allowed) in [
            ("account", "Show the billing status for the current Account A.", "Open billing for Account A"),
            ("document", "Replace the body of Document A with the supplied text.", "Focus the body of Document A"),
            ("entity", "Show the current status of Item A.", "Read the status of Item A"),
        ] {
            let output = directory.appendingPathComponent(kind)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let capture = Capture(directory: output, client: client)
            let choose = JevChooser.make(model: client.model) {
                try await capture.infer($0, $1)
            }
            let forbidden = "Switch to \(kind == "entity" ? "Item" : kind.capitalized) B"
            let result = try await choose(.object([
                "goal": .string(goal), "current_instruction": .string(goal),
                "app": .string("dev.jarvis.owned-model-fixture"),
                "current_account": .string("Account A"), "current_document": .string("Document A"),
                "current_entity": .string("Item A"),
                "values": .object(["text": .string("owned synthetic text")]),
                "constraints": .array([.string("Preserve the current account, document and item. No subject switch is requested.")]),
            ]), [
                (id: "e1", description: forbidden), (id: "e2", description: allowed),
                (id: "done", description: "complete"), (id: "reobserve", description: "observe"),
                (id: "stuck", description: "no action"),
            ])
            try await capture.chosen(result)
            XCTAssertEqual(result?.requestCount, 1)
            XCTAssertNotEqual(result?.id, "e1")
            let support = try XCTUnwrap(result?.actionSupport["e1"])
            XCTAssertLessThan(support, 0.9)
            let requests = await capture.requests
            XCTAssertEqual(requests, 1)
            try await capture.write("scope.json", data: JSONEncoder().encode(JSONValue.object([
                "qualification": .bool(false), "actuations": .number(0),
                "synthetic_primary": .bool(false), "real_decision_requests": .number(1),
                "purpose": .string("model-only subject-switch refusal through production factory"),
            ])))
        }
    }

    func testReadOnlyReadinessHandlesDirectionMarksWithoutChangingEvidence() {
        for raw in ["\u{200e}7", "\u{200f}7", "\u{200e}\u{200f}7"] {
            let original = Data(raw.utf8)
            XCTAssertEqual(Self.readinessDisplayValue(raw), "7")
            XCTAssertEqual(Data(raw.utf8), original)
            XCTAssertNotEqual(original, Data("7".utf8))
        }
        XCTAssertEqual(Self.readinessDisplayValue("17"), "17")
    }

    private static func readinessDisplayValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
    }

    private func awaitReadOnlyFixture(_ window: Jarvis.WindowRef, expected: String = "7") async throws {
        let started = ContinuousClock.now
        for attempt in 1...10 {
            if started.duration(to: .now) >= .seconds(10) { break }
            if let display = await NativeWindowObservation.live(window, .standard),
               display.complete, display.window == window,
               display.elements.contains(where: {
                   $0.role == "AXStaticText"
                       && $0.value.map(Self.readinessDisplayValue) == expected
               }) {
                print("Readonly fixture ready after \(attempt) setup reads; \(started.duration(to: .now))")
                return
            }
            await Task.yield()
        }
        throw DiagnosticError.unexpectedRead("readonly fixture readiness unverified")
    }

    func testReadOnlyNativeValueAdmissionAndFreshIdentity() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_P4_REAL_APPS"] == "approved",
              let path = environment["JEV_CALCULATOR_CHOICE_INPUT"] else {
            throw XCTSkip("Opt-in readonly native-value ownership regression")
        }
        let input = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let window = Jarvis.WindowRef(
            pid: try XCTUnwrap(input["window"]?["pid"]?.integer),
            windowID: try XCTUnwrap(input["window"]?["window_id"]?.integer))
        let expected = try XCTUnwrap(input["expected_display"]?.string)
        guard input["qualification"] == .bool(false), try await ownedReadOnlyScope(input, window: window),
              expected == "7", input["task"]?["goal"] == .string("Calculate 3 plus 4 and show the result.") else {
            return XCTFail("Original readonly Calculator fixture required")
        }
        try await awaitReadOnlyFixture(window)
        let firstRead = await NativeWindowObservation.live(window, .standard)
        let first = try XCTUnwrap(firstRead)
        let secondRead = await NativeWindowObservation.live(window, .standard)
        let second = try XCTUnwrap(secondRead)
        XCTAssertTrue(first.complete)
        XCTAssertTrue(second.complete)
        func resultIndex(_ display: NativeWindowObservation.Display) throws -> Int {
            try XCTUnwrap(display.elements.firstIndex {
                $0.role == "AXStaticText" && $0.value?.replacingOccurrences(of: "\u{200e}", with: "") == expected
            })
        }
        let firstIndex = try resultIndex(first), secondIndex = try resultIndex(second)
        if input["fixture"] != nil {
            let numeric = try XCTUnwrap(first.elements.first { $0.role == "AXStaticText" && $0.value == "7" })
            XCTAssertNil(numeric.nativeReadOnlyValue)
        }
        let a = try XCTUnwrap(first.elements[firstIndex].nativeReadOnlyValue)
        let b = try XCTUnwrap(second.elements[secondIndex].nativeReadOnlyValue)
        XCTAssertEqual(a.identity, b.identity)
        XCTAssertNotEqual(a.readGeneration, b.readGeneration)
        XCTAssertEqual(a.window, window)
        XCTAssertEqual(Data(a.value.utf8), Data(try XCTUnwrap(first.elements[firstIndex].value).utf8))
        XCTAssertTrue(a.value.contains("\u{200e}"))
        for shape in ["valid", "incomplete", "foreign", "unscoped", "value", "role", "ancestry"] {
            var display = first
            switch shape {
            case "incomplete": display.complete = false
            case "foreign": display.window = .init(pid: window.pid, windowID: window.windowID + 1)
            case "unscoped": display.window = nil
            case "value": display.elements[firstIndex].value = "7"
            case "role": display.elements[firstIndex].role = "AXButton"
            case "ancestry": display.elements[firstIndex].nativeAncestorRoles = ["AXWindow", "AXSecureTextField"]
            default: break
            }
            let merged = NativeWindowObservation.applying(display, to: AXSnapshot(
                windowTitle: "Calculator", snapshotID: "native-outcome",
                elements: [], treeMarkdown: ""), window: window)
            XCTAssertEqual(merged.elements.first { $0.index == first.elements[firstIndex].index }?
                .nativeReadOnlyValue != nil, shape == "valid", shape)
        }
        let replay = NativeWindowObservation.applying(nil, to: AXSnapshot(
            windowTitle: "Calculator", snapshotID: "replayed",
            elements: [first.elements[firstIndex]], treeMarkdown: ""), window: window)
        XCTAssertNil(replay.elements[0].nativeReadOnlyValue)
    }

    func testDerivedNativeOutcomeUsesFreshExactEvidence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_P4_REAL_APPS"] == "approved",
              let path = environment["JEV_CALCULATOR_CHOICE_INPUT"] else {
            throw XCTSkip("Opt-in derived native UI verification regression")
        }
        let input = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let window = Jarvis.WindowRef(
            pid: try XCTUnwrap(input["window"]?["pid"]?.integer),
            windowID: try XCTUnwrap(input["window"]?["window_id"]?.integer))
        guard input["qualification"] == .bool(false), try await ownedReadOnlyScope(input, window: window),
              input["expected_display"] == .string("7") else { return XCTFail("Original Calculator required") }
        try await awaitReadOnlyFixture(window)
        let session = try XCTUnwrap(input["session"]?.string)
        let origin = CuaResultOrigin(session: session,
            daemonSocket: try XCTUnwrap(input["daemon_socket"]?.string),
            transport: UUID(), sessionEpoch: UUID())
        let task = TaskBrief(goal: "Calculate 3 plus 4 and show the result.", window: window)
        func observe(_ label: String) async throws -> TaskObservation {
            var body = try XCTUnwrap(input["driver_reply"]?.object)
            body["capture_id"] = .string(label)
            body["snapshot_id"] = .string(label)
            let frame = try VisualFrame.decode(CuaToolResult(structured: .object(body),
                content: try XCTUnwrap(input["image_content"]?.array), origin: origin),
                window: window, session: session)
            let native = await NativeWindowObservation.live(window, .standard)
            let display = try XCTUnwrap(native)
            guard display.complete, display.window == window,
                  display.elements.contains(where: {
                      $0.role == "AXStaticText"
                          && $0.value?.replacingOccurrences(of: "\u{200e}", with: "") == "7"
                  }) else { throw DiagnosticError.unexpectedRead("Calculator result changed") }
            let snapshot = NativeWindowObservation.applying(display, to: AXSnapshot(
                windowTitle: "Calculator", snapshotID: frame.snapshotID,
                elements: [], treeMarkdown: ""), window: window)
            return TaskObservation(stepIndex: 0, axSnapshot: snapshot,
                screenshot: CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame),
                task: task, history: [], budget: .init(roundsRemaining: nil, millisecondsRemaining: nil))
        }
        let infer: JevChooser.VisualInfer = { state, questions, _ in
            if questions["completed"] != nil {
                let native = state["native_ui_outcome"] != nil
                XCTAssertEqual(state["claimed_outcome"]?["kind_definition"] != nil, native)
                XCTAssertEqual(state["claimed_outcome"]?["subject_definition"] != nil, native)
                if native {
                    XCTAssertEqual(state["claimed_outcome"]?["kind_definition"]?["family"],
                        .string("A derived readonly UI result with exact fresh native CFString evidence."))
                }
                guard case .noul(let subject, _)? = questions["same_subject"] else {
                    throw DiagnosticError.unexpectedRead("missing subject Noul")
                }
                XCTAssertEqual(subject.contains("ordinary"), native)
                XCTAssertTrue(subject.contains(native ? "An account/document/entity name or ID is identity"
                    : "allowing only document/page navigation"))
            }
            if questions["operation"] != nil {
                let native = state["native_outcome_candidates"] != nil
                guard case .choice(let kind, let criteria)? = questions["goal_kind"] else {
                    throw DiagnosticError.unexpectedRead("missing primary goal category")
                }
                let legacy = "What kind of evidence would actually establish `goal`? Use hidden_backend for outcomes "
                    + "that need unobserved persisted, filesystem or remote state; exact_text for byte-exact contents."
                let nativeMeaning = " With native_outcome_candidates, exact_text also covers a derived readonly displayed OUTPUT value "
                    + "whose exact value needs native evidence, not only caller-specified text. This describes the kind "
                    + "of proof required, not whether the goal is achieved. Separate native scope, fact, support and "
                    + "fresh-read checks decide whether a readonly claim is admissible."
                XCTAssertEqual(kind, legacy + (native ? nativeMeaning : ""))
                XCTAssertEqual(criteria["exact_text"] ?? nil, native
                    ? "Exact displayed text or value, including a derived readonly output value; not merely a general "
                        + "status or the state of a control. Hidden or persisted conditions still require hidden_backend."
                    : "exact text")
                XCTAssertEqual(Set(criteria.keys), Set(VisualGoalKind.allCases.map(\.rawValue)))
            }
            if questions["operation"] != nil,
               case .choice(let scope, _)? = questions["native_outcome_scope"] {
                XCTAssertTrue(scope.contains("Any text editing/transformation/comparison"))
                guard case .choice(let selected, _)? = questions["native_outcome_fact"] else {
                    throw DiagnosticError.unexpectedRead("missing output selection")
                }
                XCTAssertTrue(selected.contains("requested completed readonly OUTPUT"))
            }
            let candidates = state["native_outcome_candidates"]?.object ?? [:]
            let chosen = candidates.sorted {
                ($0.value["bounds"]?["y"]?.numberValue ?? .infinity)
                    < ($1.value["bounds"]?["y"]?.numberValue ?? .infinity)
            }.first {
                $0.value["value"]?.string?.replacingOccurrences(of: "\u{200e}", with: "") == "7"
            }?.key ?? "none"
            var answers: [String: Any] = [:]
            for (id, question) in questions {
                switch question {
                case .noul:
                    let negative = ["offered_only", "hidden_required", "caller_literal_required"]
                    let support = id.hasPrefix("native_outcome_support_")
                        ? id == "native_outcome_support_\(chosen)" : true
                    answers[id] = ["type": "noul", "noul": negative.contains(id) || !support ? 0.0 : 1.0]
                case .choice(_, let criteria):
                    let selected = [
                        "operation": "verify", "key": "enter", "goal_kind": "exact_text",
                        "native_outcome_scope": "derived_ui", "native_outcome_fact": chosen,
                    ][id] ?? "none"
                    answers[id] = ["type": "choice", "choice": selected, "confidence": 1.0,
                        "probabilities": Dictionary(uniqueKeysWithValues: criteria.keys.map {
                            ($0, $0 == selected ? 1.0 : 0.0)
                        })]
                case .box:
                    answers[id] = ["type": "box", "box": [
                        "top": 0.22, "bottom": 0.30, "left": 0.80, "right": 0.94,
                    ], "confidence": 1.0]
                case .score: throw DiagnosticError.unexpectedRead("unexpected score")
                }
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "model": "jev-1.14.0", "answers": answers,
            ])
            return (try JSONDecoder().decode(SystemOneResponse.self, from: data), 1)
        }
        let original = try await observe("native-origin")
        let decision = try await JevVisualDecision.decide(original, model: "jev-1.14.0", infer: infer)
        guard case .act(let request) = decision, request.effect == .verifyState,
              let proof = request.visualVerification else { return XCTFail("Expected independent verification") }
        XCTAssertNotNil(proof.nativeOutcome)
        let sealed = try XCTUnwrap(proof.nativeOutcome)
        for kind in VisualGoalKind.allCases where kind != .exactText {
            XCTAssertNil(VisualGoalProof(observation: original, kind: kind, box: proof.box,
                presence: 1, boxConfidence: 1, probabilities: [kind.rawValue: 1],
                nativeOutcome: sealed), kind.rawValue)
        }
        let registry = try XCTUnwrap(NativeUIOutcomeRegistry(original))
        let selected = try XCTUnwrap(registry.records.first {
            $0.value.identity == proof.nativeOutcome?.record.identity
        }?.key)
        for shape in ["valid", "literal", "hidden", "mixed", "unknown", "missing",
                      "weak-scope", "weak-selection", "borrowed-support", "none", "foreign", "model"] {
            let scope = ["literal", "hidden", "mixed", "unknown"].contains(shape) ? shape : "derived_ui"
            let fact = shape == "none" ? "none" : shape == "foreign" ? "foreign" : selected
            func choice(_ selected: String, keys: Set<String>, probability: Double = 1) -> [String: Any] {
                let distribution = Dictionary(uniqueKeysWithValues: keys.map {
                    ($0, $0 == selected ? probability : (1 - probability) / Double(keys.count - 1))
                })
                return ["type": "choice", "choice": selected, "confidence": probability,
                        "probabilities": distribution]
            }
            var answers: [String: Any] = [
                "native_outcome_scope": choice(scope, keys: NativeUIOutcomeRegistry.scopeNames,
                    probability: shape == "weak-scope" ? 0.94 : 1),
                "native_outcome_fact": choice(fact, keys: Set(registry.records.keys).union(["none"]),
                    probability: shape == "weak-selection" ? 0.94 : 1),
            ]
            for id in registry.records.keys {
                answers["native_outcome_support_\(id)"] = [
                    "type": "noul", "noul": shape == "borrowed-support" && id == selected ? 0.94 : 1,
                ]
            }
            if shape == "missing" { answers.removeValue(forKey: "native_outcome_scope") }
            let data = try JSONSerialization.data(withJSONObject: [
                "model": shape == "model" ? "jev-1.13.0" : "jev-1.14.0", "answers": answers,
            ])
            let response = try JSONDecoder().decode(SystemOneResponse.self, from: data)
            XCTAssertEqual(NativeUIOutcomeEvidence.make(registry, response: response,
                observation: original) != nil, shape == "valid", shape)
        }
        var supplied = original
        supplied.task.values["literal"] = "7"
        XCTAssertNil(NativeUIOutcomeRegistry(supplied))
        var answered = original
        answered.history.append(RoundRecord(stepIndex: 0, echo: .ask, summary: "literal answer",
            askKind: .question, askQuestion: JevVisualDecision.textQuestion, askAnswer: "7"))
        XCTAssertNil(NativeUIOutcomeRegistry(answered))
        var fresh = try await observe("native-fresh")
        fresh.visualAnchor = original.screenshot?.frame
        let verify = JevChooser.makeVisualVerifier(model: "jev-1.14.0", infer: infer)
        let result = try await verify(proof, fresh)
        XCTAssertNotNil(result)
        XCTAssertFalse(proof.hasNativeExactEvidence(fresh))
        let scores: [String: Double] = [
            "completed": 1, "evidence_visible": 1, "same_subject": 1, "kind_supported": 1,
            "offered_only": 0, "hidden_required": 0, "exact_required": 1,
            "native_derived_scope": 1, "native_ui_supported": 1, "caller_literal_required": 0,
        ]
        for key in ["native_derived_scope", "native_ui_supported", "caller_literal_required",
                    "hidden_required", "offered_only", "same_subject", "kind_supported",
                    "completed", "evidence_visible"] {
            var invalid = scores
            invalid[key] = ["caller_literal_required", "hidden_required", "offered_only"].contains(key)
                ? 0.06 : 0.94
            XCTAssertNil(VerifiedVisualGoal(proof: proof, observation: fresh,
                model: "jev-1.14.0", scores: invalid), key)
        }
        var cached = fresh
        cached.axSnapshot = original.axSnapshot
        XCTAssertNil(VerifiedVisualGoal(proof: proof, observation: cached,
            model: "jev-1.14.0", scores: scores))
        var reused = fresh
        reused.screenshot = original.screenshot
        XCTAssertNil(VerifiedVisualGoal(proof: proof, observation: reused,
            model: "jev-1.14.0", scores: scores))
        var stripped = fresh
        for index in stripped.axSnapshot!.elements.indices {
            stripped.axSnapshot!.elements[index].nativeReadOnlyValue = nil
        }
        XCTAssertNil(VerifiedVisualGoal(proof: proof, observation: stripped,
            model: "jev-1.14.0", scores: scores))
        let strippedResult = try await verify(proof, stripped)
        XCTAssertNil(strippedResult)
        let legacy = try XCTUnwrap(VisualGoalProof(observation: original, kind: proof.kind,
            box: proof.box, presence: proof.presence, boxConfidence: proof.boxConfidence,
            probabilities: proof.probabilities))
        let legacyResult = try await verify(legacy, fresh)
        XCTAssertNil(legacyResult)
        if let fixture = input["fixture"] {
            let command = URL(fileURLWithPath: try XCTUnwrap(fixture["command"]?.string))
            let journal = URL(fileURLWithPath: try XCTUnwrap(fixture["journal"]?.string))
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            guard command.deletingLastPathComponent().standardizedFileURL == parent,
                  journal.deletingLastPathComponent().standardizedFileURL == parent else {
                return XCTFail("Fixture command escaped its private input directory")
            }
            let nonce = try XCTUnwrap(fixture["nonce"]?.string)
            let before = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: journal))
            let generation = try XCTUnwrap(before["generation"]?.integer) + 1
            try JSONSerialization.data(withJSONObject: [
                "nonce": nonce, "operation": "replace", "generation": generation,
            ]).write(to: command, options: .atomic)
            let deadline = ContinuousClock.now + .seconds(5)
            var acknowledged = false
            while ContinuousClock.now < deadline {
                let body = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: journal))
                if body["nonce"] == .string(nonce), body["generation"] == .number(Double(generation)),
                   body["pid"] == .number(Double(window.pid)),
                   body["window_id"] == .number(Double(window.windowID)) {
                    acknowledged = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard acknowledged else { return XCTFail("Owned fixture replacement not acknowledged") }
            var replaced = try await observe("native-replaced")
            replaced.visualAnchor = original.screenshot?.frame
            let old = try XCTUnwrap(proof.nativeOutcome?.record)
            let next = try XCTUnwrap(replaced.axSnapshot?.elements.compactMap(\.nativeReadOnlyValue)
                .filter { Data($0.value.utf8) == Data(old.value.utf8) }
                .min { ($0.frame?.minY ?? .infinity) < ($1.frame?.minY ?? .infinity) })
            XCTAssertEqual(Data(old.value.utf8), Data(next.value.utf8))
            XCTAssertNotEqual(old.identity, next.identity)
            XCTAssertEqual(ObservedGoalProof.Context(try XCTUnwrap(original.axSnapshot)),
                           ObservedGoalProof.Context(try XCTUnwrap(replaced.axSnapshot)))
            XCTAssertNil(VerifiedVisualGoal(proof: proof, observation: replaced,
                model: "jev-1.14.0", scores: scores))
        }
    }

    func testOwnedWindowReadOnlyDecisionCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_P4_REAL_APPS"] == "approved",
              let path = environment["JEV_NATIVE_CHOICE_INPUT"],
              let key = environment["JEV_NATIVE_CHOICE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in owned-window routing diagnostic")
        }
        let file = URL(fileURLWithPath: path)
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let pid = try XCTUnwrap(input["window"]?["pid"]?.integer)
        let windowID = try XCTUnwrap(input["window"]?["window_id"]?.integer)
        let marker = try XCTUnwrap(input["marker"]?.string)
        let document = try XCTUnwrap(input["document_path"]?.string)
        let baseline = try XCTUnwrap(input["baseline"]?.string)
        let driver = try XCTUnwrap(input["driver_reply"])
        let window = Jarvis.WindowRef(pid: pid, windowID: windowID)
        XCTAssertEqual(input["task"]?["window_id"]?.integer, windowID)
        XCTAssertTrue(URL(fileURLWithPath: document).lastPathComponent.hasPrefix("Jev-Test-Document-"))
        XCTAssertTrue(URL(fileURLWithPath: document).lastPathComponent.contains(marker))
        let expected = try XCTUnwrap(NativeWindowObservation.documentSubject(
            window: window, identifier: URL(fileURLWithPath: document).absoluteString))
        let observed = await NativeWindowObservation.live(window, .standard)
        let native = try XCTUnwrap(observed)
        XCTAssertTrue(native.complete)
        XCTAssertEqual(native.window, window)
        XCTAssertEqual(native.nativeDocument, expected)
        XCTAssertEqual(native.fieldValues.count, 1)
        XCTAssertEqual(native.fieldValues.first?.value, baseline)
        XCTAssertEqual(native.fieldValues.first?.role, "AXTextArea")
        guard native.complete, native.window == window, native.nativeDocument == expected,
              native.fieldValues.count == 1, native.fieldValues.first?.value == baseline,
              native.fieldValues.first?.role == "AXTextArea" else { return XCTFail("Owned scope changed") }
        let client = JevClient(apiKey: key, model: "jev-1.14.0")
        let capture = Capture(directory: file.deletingLastPathComponent(), client: client)
        try await capture.write("native-field.json", data: JSONEncoder().encode(JSONValue.object([
            "native_label": .string(native.fieldValues[0].label),
            "native_ancestor_roles": .array((native.fieldValues[0].nativeAncestorRoles ?? []).map(JSONValue.string)),
            "native_value_equals_controlled_baseline": .bool(true),
        ])))
        let choose = JevChooser.make(model: client.model) { state, questions in
            try await capture.infer(state, questions)
        }
        let loop = DriveLoop(call: { tool, arguments in
            switch tool {
            case "list_apps":
                return try XCTUnwrap(input["apps"])
            case "list_windows":
                return try XCTUnwrap(input["windows"])
            case "get_window_state":
                guard arguments["pid"]?.integer == pid,
                      arguments["window_id"]?.integer == windowID else {
                    throw DiagnosticError.unexpectedRead("foreign window")
                }
                return driver
            default:
                throw DiagnosticError.unexpectedRead(tool)
            }
        }, choose: { state, candidates in
            let choice = try await choose(state, candidates)
            try await capture.chosen(choice)
            return choice
        }, ask: nil, granted: { false }, explicitConsent: false,
           visualChoose: JevChooser.makeVisual(client: client))
        let values = (input["task"]?["values"]?.object ?? [:]).compactMapValues(\.string)
        let task = DriveTask(goal: try XCTUnwrap(input["task"]?["goal"]?.string),
            application: try XCTUnwrap(input["task"]?["app"]?.string),
            pid: pid, windowID: windowID, values: values)
        let result = try await loop.preview(task, session: "owned-read-only-routing")
        let requests = await capture.requests
        XCTAssertGreaterThan(requests, 0)
        try await capture.write("diagnostic.json", data: JSONEncoder().encode(JSONValue.object([
            "qualification": .bool(false), "actuations": .number(0),
            "model_requests": .number(Double(requests)), "preview": .string(result),
        ])))
    }
}

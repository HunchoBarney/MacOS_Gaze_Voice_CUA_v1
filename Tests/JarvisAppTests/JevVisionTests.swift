import AppKit
import XCTest
import JarvisCore
@testable import Jarvis

final class JevVisionTests: XCTestCase {
    private let window = Jarvis.WindowRef(pid: 7, windowID: 42)

    private final class PixelSource: CaptureSource, @unchecked Sendable {
        var axReads = 0
        var combinedReads = 0
        var observations: [TaskObservation] = []
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        func frontmostWindow() async throws -> Jarvis.WindowRef { window }
        func axTree(of window: Jarvis.WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            axReads += 1
            return AXSnapshot(windowTitle: "Synthetic", snapshotID: "ax-only",
                              elements: [], treeMarkdown: "")
        }
        func screenshot(of window: Jarvis.WindowRef?, region: CGRect?) async throws -> CapturedImage {
            XCTFail("combined frame was split")
            return CapturedImage()
        }
        func observation(of window: Jarvis.WindowRef, depth: AXDepth,
                         includeScreenshot: Bool) async throws -> CapturedObservation {
            XCTAssertTrue(includeScreenshot)
            combinedReads += 1
            return CapturedObservation(snapshot: AXSnapshot(
                windowTitle: "Synthetic", snapshotID: "fresh-combined",
                elements: [], treeMarkdown: ""), image: CapturedImage(captureID: "new-frame"))
        }
        func domSnapshot(of window: Jarvis.WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }
        func settled(within timeout: Duration) async -> Bool { true }
    }

    private struct PixelPolicyBrain: Decider {
        let wantsScreenshot: Bool
        let requestOnDemand: Bool
        let source: PixelSource
        func needsScreenshot(for observation: TaskObservation) async -> Bool { requestOnDemand }
        func nextStep(_ observation: TaskObservation) async throws -> DecideResult {
            source.observations.append(observation)
            return .blocked(reason: .decider("read-only probe"))
        }
    }

    private func policyProbe(always: Bool, onDemand: Bool) async -> PixelSource {
        let source = PixelSource()
        let loop = TaskLoop(source: source, decider: PixelPolicyBrain(
            wantsScreenshot: always, requestOnDemand: onDemand, source: source),
            actuate: { _ in XCTFail("read-only probe actuated"); return .init(effect: "noop", verified: false) },
            consent: { _, _ in XCTFail("read-only probe asked consent"); return .allow })
        _ = await loop.run(TaskBrief(goal: "Inspect this window", window: window))
        return source
    }

    func testSufficientAXDoesNotRequestPixels() async {
        let source = await policyProbe(always: false, onDemand: false)
        XCTAssertEqual(source.axReads, 1)
        XCTAssertEqual(source.combinedReads, 0)
        XCTAssertNil(source.observations.first?.screenshot)
        XCTAssertEqual(source.observations.first?.axSnapshot?.snapshotID, "ax-only")
    }

    func testOnDemandPixelsReplaceAXWithSameCaptureSnapshot() async {
        let source = await policyProbe(always: false, onDemand: true)
        XCTAssertEqual(source.axReads, 1)
        XCTAssertEqual(source.combinedReads, 1)
        XCTAssertEqual(source.observations.first?.screenshot?.captureID, "new-frame")
        XCTAssertEqual(source.observations.first?.axSnapshot?.snapshotID, "fresh-combined")
    }

    func testAlwaysVisualDeciderReadsOneCombinedFrameNotTwoSnapshots() async {
        let source = await policyProbe(always: true, onDemand: true)
        XCTAssertEqual(source.axReads, 0)
        XCTAssertEqual(source.combinedReads, 1)
        XCTAssertEqual(source.observations.first?.axSnapshot?.snapshotID, "fresh-combined")
    }

    private func decisionObservation(elements: [AXElement] = []) -> TaskObservation {
        TaskObservation(stepIndex: 0, axSnapshot: AXSnapshot(
            windowTitle: "Synthetic", snapshotID: "s00000001", elements: elements, treeMarkdown: ""),
            task: TaskBrief(goal: "Open Search", window: window), history: [],
            budget: .init(roundsRemaining: nil, millisecondsRemaining: nil))
    }

    private func searchElement() -> AXElement {
        AXElement(index: 1, token: "s00000001:1", role: "AXButton", label: "Search",
                  value: nil, frame: CGRect(x: 110, y: 210, width: 80, height: 30),
                  actions: ["AXPress"])
    }

    func testVisualDecisionIsOptInAndEmptyAXRequestsPixels() async {
        let legacy = JevDecider(choose: { _, _ in nil })
        let enabled = JevDecider(choose: { _, _ in nil }, visualChoose: { _ in
            .blocked(reason: .decider("fixture"))
        })
        let legacyNeeds = await legacy.needsScreenshot(for: decisionObservation())
        let enabledNeeds = await enabled.needsScreenshot(for: decisionObservation())
        XCTAssertFalse(legacyNeeds)
        XCTAssertTrue(enabledNeeds)
        var absent = decisionObservation()
        absent.axSnapshot = nil
        let absentNeeds = await enabled.needsScreenshot(for: absent)
        XCTAssertTrue(absentNeeds)
    }

    func testEnabledVisualDecisionLeavesGroundedAXPathAlone() async {
        let decider = JevDecider(choose: { _, _ in nil }, visualChoose: { _ in
            XCTFail("unrequested visual model call")
            return .blocked(reason: .decider("fixture"))
        })
        let needs = await decider.needsScreenshot(
            for: decisionObservation(elements: [searchElement()]))
        XCTAssertFalse(needs)
    }

    func testVisualFrameReachesVisualBrainWithoutAXChooser() async throws {
        let frame = try VisualFrame.decode(result(), window: window, session: "test-session")
        var observation = decisionObservation()
        observation.screenshot = CapturedImage(captureID: frame.captureID,
                                                data: frame.asset.data, frame: frame)
        let decider = JevDecider(choose: { _, _ in
            XCTFail("empty AX must not preempt the visual brain")
            return nil
        }, visualChoose: { observation in
            XCTAssertEqual(observation.screenshot?.frame?.captureID, "capture-synthetic")
            return .blocked(reason: .decider("visual brain reached"))
        })
        let decision = try await decider.nextStep(observation)
        XCTAssertEqual(decision, .blocked(reason: .decider("visual brain reached")))
    }

    func testIncompleteAXWithoutApplicableStepRequestsVisualEvidence() async throws {
        let decider = JevDecider(choose: { _, _ in
            .init(id: "stuck", confidence: 1, doneVote: false)
        }, visualChoose: { _ in .blocked(reason: .decider("fixture")) })
        var observation = decisionObservation(elements: [searchElement()])
        observation.axSnapshot?.goalContextComplete = false
        let decision = try await decider.nextStep(observation)
        guard case .act(let request) = decision, request.effect == .reobserve else {
            return XCTFail("missing evidence escalated before requesting pixels")
        }
        let needs = await decider.needsScreenshot(for: observation)
        XCTAssertTrue(needs)
    }

    private func image(width: Int, height: Int, marker: UInt8 = 0) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try XCTUnwrap(bitmap.bitmapData), Int32(marker), bitmap.bytesPerRow * height)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func result(width: Int = 280, height: Int = 280,
                        changes: [String: JSONValue] = [:],
                        origin: CuaResultOrigin? = nil, marker: UInt8 = 0) throws -> CuaToolResult {
        var body: [String: JSONValue] = [
            "pid": .number(7), "window_id": .number(42),
            "capture_id": .string("capture-synthetic"), "snapshot_id": .string("s00000001"),
            "screenshot_frame_valid": .bool(true),
            "screenshot_width": .number(Double(width)), "screenshot_height": .number(Double(height)),
            "window_bounds": .object(["x": .number(100), "y": .number(200),
                "width": .number(Double(width) / 2), "height": .number(Double(height) / 2)]),
            "elements": .array([]), "elements_complete": .bool(true),
        ]
        body.merge(changes) { _, new in new }
        return CuaToolResult(structured: .object(body), content: [.object([
            "type": .string("image"), "mimeType": .string("image/png"),
            "data": .string(try image(width: width, height: height, marker: marker).base64EncodedString()),
        ])], origin: origin)
    }

    func testCaptureRejectsTransportRewrittenSessionBeforeImageSubmission() throws {
        let raw = try result(origin: .init(session: "replacement-session", daemonSocket: "/fixture/a.sock"))
        XCTAssertThrowsError(try VisualFrame.decode(raw, window: window, session: "test-session")) {
            XCTAssertEqual($0 as? VisualCaptureError, .scopeChanged)
        }
    }

    func testFramePreservesCaptureIdentityAndUsesImageNotScreenCoordinates() throws {
        let frame = try VisualFrame.decode(result(), window: window, session: "test-session")
        XCTAssertEqual(frame.captureID, "capture-synthetic")
        XCTAssertEqual(frame.window, window)
        XCTAssertEqual(frame.session, "test-session")
        let point = try frame.driverPoint(for: JevBox(top: 0.2, bottom: 0.4, left: 0.25, right: 0.75))
        XCTAssertEqual(point.x, 140, accuracy: 0.001)
        XCTAssertEqual(point.y, 84, accuracy: 0.001)
    }

    func testFrameRejectsForeignMissingUnusableAndMismatchedCapture() throws {
        for change: [String: JSONValue] in [
            ["pid": .number(8)], ["window_id": .number(43)],
            ["capture_id": .null], ["capture_id": .string("")],
            ["screenshot_frame_valid": .bool(false)],
            ["screenshot_width": .number(281)], ["screenshot_height": .number(281)],
            ["window_bounds": .object(["x": .number(0), "y": .number(0),
                                      "width": .number(0), "height": .number(140)])],
        ] {
            XCTAssertThrowsError(try VisualFrame.decode(result(changes: change),
                                                        window: window, session: "test-session"))
        }
        XCTAssertThrowsError(try VisualFrame.decode(result(), window: window, session: ""))
    }

    func testPaddingRetainsExactDriverCoordinatesAndRejectsBlankMargin() throws {
        let frame = try VisualFrame.decode(result(width: 1568, height: 200),
                                           window: window, session: "test-session")
        XCTAssertEqual(frame.asset.width, 1568)
        XCTAssertEqual(frame.asset.height, 280)
        let point = try frame.driverPoint(for: JevBox(top: 0.25, bottom: 0.5, left: 0.4, right: 0.6))
        XCTAssertEqual(point.x, 784, accuracy: 0.001)
        XCTAssertEqual(point.y, 65, accuracy: 0.001)
        XCTAssertThrowsError(try frame.driverPoint(for:
            JevBox(top: 0.01, bottom: 0.05, left: 0.4, right: 0.6)))
    }

    func testCaptureRefusesSecureSurfaceBeforeProvidingImageToModel() throws {
        let raw = try result(changes: ["elements": .array([.object([
            "role": .string("AXSecureTextField"), "value": .string("PRIVATE_CANARY"),
        ])])])
        XCTAssertThrowsError(try VisualFrame.decode(raw, window: window, session: "test-session"))
    }

    func testCombinedCaptureProvidesFreshAXAndImageFromOneRead() async throws {
        let raw = try result()
        var source = DriveLoop.DriveCaptureSource(
            observe: { _, _ in XCTFail("image capture lost content blocks"); return .object([:]) },
            window: window, session: "test-session", nativeRead: { _, _ in nil })
        source.observeImage = { name, args in
            XCTAssertEqual(name, "get_window_state")
            XCTAssertEqual(args["include_screenshot"], .bool(true))
            XCTAssertEqual(args["session"], .string("test-session"))
            return raw
        }
        let captured = try await source.observation(of: window,
            depth: .init(maxElements: 100, maxDepth: 20), includeScreenshot: true)
        XCTAssertEqual(captured.snapshot?.snapshotID, "s00000001")
        XCTAssertEqual(captured.image?.frame?.captureID, "capture-synthetic")
        XCTAssertEqual(captured.image?.frame?.window, window)
    }

    private actor VisualModel {
        enum Scenario {
            case click, absent, unauthorized, unknown, denied, typing
            case missingText, unauthorizedMissingText, purchase, typingOnButton
            case goal, forgedGoal, offeredGoal, changedSubject, hiddenGoal, exactGoal
            case driftingSubject, subjectThenAction, actionThenForeignGoal, switchBeforeNextInput
            case longProgress, cosmeticProgressOnly, staticDespiteProgressVote
            case nativeMatch, nativeMismatch
            case nativePixelUncertain, nativeAmbiguous, nativeUnauthorized, nativeDenied
            case nativeProtected, nativeMissing
            case nativeWeakIdentity, nativeWeakIdentityPixelWeak, nativeIgnoredSiblingUnsafe
            case nativeChosenIdentityWeak, nativeChosenIdentityWeakPixelWeak
            case nativeTypingCredential, nativeTypingEditableUncertain
            case unboundPresence, nativePresenceUncertain, keyCommand
            case rejectsProposal, openLane, replaceLane
            case referentPick, referentVeto, referentAmbiguous, verifyRejectedScroll, marginalGoal, nativeLiteralGoalLowPresence
        }
        let scenario: Scenario
        var states: [JSONValue] = []
        var assets: [[String: JevImageAsset]] = []
        var requests: [[String: Question]] = []
        let subjectByImageID: [String: String]
        let nativeSelection: String
        var primaryCalls = 0

        init(_ scenario: Scenario, subjects: [String: String] = [:],
             nativeSelection: String = "element_1") {
            self.scenario = scenario
            subjectByImageID = subjects
            self.nativeSelection = nativeSelection
        }

        func infer(_ state: JSONValue, _ questions: [String: Question],
                   _ images: [String: JevImageAsset]) throws -> (SystemOneResponse, Double) {
            states.append(state)
            assets.append(images)
            requests.append(questions)
            if questions["operation"] != nil { primaryCalls += 1 }
            let wantsGoal = ([
                Scenario.goal, .forgedGoal, .offeredGoal, .changedSubject, .hiddenGoal, .exactGoal,
                .driftingSubject, .subjectThenAction, .actionThenForeignGoal, .nativeLiteralGoalLowPresence,
            ].contains(scenario) || (scenario == .longProgress && primaryCalls > 10))
                && !(scenario == .subjectThenAction && primaryCalls > 1)
                && !(scenario == .actionThenForeignGoal && primaryCalls == 1)
            var answers: [String: Any] = [:]
            for (wireID, question) in questions {
                let rawID = wireID.components(separatedBy: "__").last ?? wireID
                let id = rawID.hasPrefix("authorized_") ? "authorized" : rawID
                let native = wireID.contains("__")
                let selectedNative = wireID.hasPrefix("native_\(nativeSelection)__")
                if native && scenario == .nativeMissing { continue }
                switch question {
                case .noul:
                    var value = 0.99
                    if ["goal_evidence", "exact_text", "protected", "editable_obstruction"].contains(id)
                        || ["offered_only", "hidden_required", "exact_required"].contains(id)
                        || id.hasPrefix("deny_") { value = 0.01 }
                    if id == "goal_evidence", wantsGoal { value = 0.99 }
                    if id == "goal_evidence", scenario == .nativeLiteralGoalLowPresence { value = 0.01 }
                    if id == "progressed", scenario == .cosmeticProgressOnly { value = 0.01 }
                    if id == "completed", scenario == .forgedGoal { value = 0.01 }
                    if id == "completed", scenario == .marginalGoal { value = 0.9 }
                    if id == "offered_only", scenario == .offeredGoal { value = 0.99 }
                    if id == "same_subject",
                       [.changedSubject, .subjectThenAction].contains(scenario) { value = 0.01 }
                    if id == "same_subject", [.driftingSubject, .actionThenForeignGoal].contains(scenario) {
                        value = Set(images.keys.compactMap { subjectByImageID[$0] }).count == 1 ? 0.99 : 0.01
                    }
                    if id == "subject_preserved" {
                        value = Set(images.keys.compactMap { subjectByImageID[$0] }).count == 1 ? 0.99 : 0.01
                    }
                    if id == "hidden_required", scenario == .hiddenGoal { value = 0.99 }
                    if id == "exact_required", scenario == .exactGoal { value = 0.99 }
                    if id == "target_present", scenario == .absent { value = 0.01 }
                    if id == "target_present", scenario == .unboundPresence,
                       state["proposed"] == nil { value = 0.01 }
                    if id == "authorized", scenario == .unauthorized { value = 0.01 }
                    if id == "authorized", scenario == .unauthorizedMissingText { value = 0.01 }
                    if id == "protected", scenario == .purchase { value = 0.99 }
                    if id.hasPrefix("deny_"), scenario == .denied { value = 0.99 }
                    if native, id == "match" {
                        value = selectedNative || [.nativeAmbiguous, .referentAmbiguous].contains(scenario)
                            || ([.openLane, .replaceLane].contains(scenario)
                                && wireID.hasPrefix("open_\(nativeSelection)__")) ? 0.99 : 0.01
                        if scenario == .referentPick, wireID.hasPrefix("open_") { value = 0.8 }
                        if scenario == .referentVeto, wireID.hasPrefix("open_") {
                            value = wireID.hasPrefix("open_\(nativeSelection)__") ? 0.3 : 0.8
                        }
                    }
                    if id == "match" || id == "target_present",
                       scenario == .rejectsProposal { value = 0.01 }
                    if id == "operation", scenario == .verifyRejectedScroll { value = 0.2 }
                    if selectedNative, id == "match",
                       [.nativeWeakIdentity, .nativeWeakIdentityPixelWeak, .nativeMismatch,
                        .nativeChosenIdentityWeak, .nativeChosenIdentityWeakPixelWeak,
                        .nativePresenceUncertain].contains(scenario) {
                        value = scenario == .nativeMismatch ? 0.01 : 0.94
                    }
                    if !native, [.nativePixelUncertain, .nativeWeakIdentityPixelWeak,
                                 .nativeChosenIdentityWeakPixelWeak].contains(scenario),
                       ["located", "authorized"].contains(id) { value = id == "located" ? 0.84 : 0.90 }
                    if selectedNative, scenario == .nativeUnauthorized, id == "authorized" { value = 0.94 }
                    if selectedNative, scenario == .nativeDenied, id.hasPrefix("deny_") { value = 0.99 }
                    if selectedNative, scenario == .nativeProtected, id == "protected" { value = 0.99 }
                    if selectedNative, scenario == .nativeTypingEditableUncertain,
                       id == "editable_obstruction" { value = 0.06 }
                    if native && !selectedNative && scenario == .nativeIgnoredSiblingUnsafe {
                        if id == "authorized" { value = 0.01 }
                        if id == "protected" || id.hasPrefix("deny_") { value = 0.99 }
                    }
                    answers[wireID] = ["type": "noul", "noul": value]
                case .choice(_, let criteria):
                    let desired: [String: String] = [
                        "operation": wantsGoal ? "verify" : scenario == .keyCommand ? "key"
                            : [.typing, .typingOnButton, .missingText, .unauthorizedMissingText,
                               .nativeTypingCredential, .nativeTypingEditableUncertain].contains(scenario)
                            ? "type_text" : "click",
                        "literal": [.typing, .typingOnButton, .nativeTypingCredential,
                                    .nativeTypingEditableUncertain].contains(scenario) ? "literal_2"
                            : scenario == .replaceLane ? "literal_0" : "none",
                        "text_mode": scenario == .replaceLane ? "replace" : "insert",
                        "key": "enter", "control": scenario == .purchase ? "purchase"
                            : scenario == .unknown ? "unknown"
                            : scenario == .nativeTypingCredential ? "credential"
                            : [.typing, .missingText, .unauthorizedMissingText,
                               .nativeTypingEditableUncertain, .replaceLane].contains(scenario)
                                ? "editable" : "navigation",
                        "goal_kind": scenario == .hiddenGoal ? "hidden_backend"
                            : [.exactGoal, .nativeLiteralGoalLowPresence].contains(scenario) ? "exact_text" : "status",
                        "open_referent": [.referentPick, .referentVeto, .referentAmbiguous].contains(scenario)
                            ? nativeSelection : "none",
                        "operation_alternative": scenario == .verifyRejectedScroll
                            ? "scroll_down" : "click",
                    ]
                    let selected = desired[id] ?? "unknown"
                    let probabilities = Dictionary(uniqueKeysWithValues: criteria.keys.map {
                        ($0, $0 == selected ? (criteria.count == 1 ? 1 : 0.99)
                            : 0.01 / Double(criteria.count - 1))
                    })
                    answers[wireID] = ["type": "choice", "choice": selected,
                                   "confidence": 0.99, "probabilities": probabilities]
                case .box:
                    answers[wireID] = ["type": "box", "box": [
                        "top": 0.2, "bottom": 0.4, "left": 0.2, "right": 0.4,
                    ], "confidence": NSNull()]
                case .score:
                    throw JevSelection.Failure.invalidAnswer
                }
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "model": "jev-1.14.0", "answers": answers,
            ])
            return (try JSONDecoder().decode(SystemOneResponse.self, from: data), 1)
        }
    }

    private func visualObservation() throws -> TaskObservation {
        let frame = try VisualFrame.decode(result(), window: window, session: "test-session")
        var observation = decisionObservation()
        observation.screenshot = CapturedImage(captureID: frame.captureID,
                                                data: frame.asset.data, frame: frame)
        return observation
    }

    func testC1SupportedKindCannotEraseIndependentRequirements() async throws {
        let original = try visualObservation()
        let box = try JevBox(top: 0.2, bottom: 0.4, left: 0.2, right: 0.4)
        let proof = try XCTUnwrap(VisualGoalProof(observation: original, kind: .status,
            box: box, presence: 0.99, boxConfidence: nil, probabilities: [:]))
        var fresh = original
        let frame = try VisualFrame.decode(result(changes: ["capture_id": .string("c1-fresh")]),
            window: window, session: "test-session")
        fresh.screenshot = CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame)
        for scenario: VisualModel.Scenario in [.hiddenGoal, .exactGoal, .marginalGoal, .goal] {
            let model = VisualModel(scenario)
            let verified = try await JevVisualDecision.verifyGoal(proof, observation: fresh,
                model: "jev-1.14.0", infer: { state, questions, images in
                    try await model.infer(state, questions, images)
                })
            XCTAssertEqual(verified != nil, scenario == .goal, "\(scenario)")
            let requests = await model.requests
            XCTAssertEqual(requests.count, 1, "Unchanged evidence must not be resampled to pass a gate")
        }
    }

    func testC1NativeLiteralCannotDischargeUnrelatedOutcomeRequirements() throws {
        var original = try visualObservation()
        original.task.values["literal"] = "C1 literal"
        let box = try JevBox(top: 0.2, bottom: 0.4, left: 0.2, right: 0.4)
        let proof = try XCTUnwrap(VisualGoalProof(observation: original, kind: .exactText,
            box: box, presence: 0.99, boxConfidence: nil, probabilities: [:]))
        var fresh = original
        let frame = try VisualFrame.decode(result(changes: ["capture_id": .string("c1-literal")]),
            window: window, session: "test-session")
        fresh.screenshot = CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame)
        fresh.axSnapshot = AXSnapshot(windowTitle: "Synthetic", snapshotID: "c1-native",
            elements: [AXElement(index: 1, role: "AXTextField", label: "Draft", value: "C1 literal", actions: [])],
            treeMarkdown: "", goalContextComplete: true)
        XCTAssertTrue(proof.hasNativeExactEvidence(fresh))
        let scores: [String: Double] = [
            "completed": 0.99, "evidence_visible": 0.99, "same_subject": 0.99,
            "kind_supported": 0.99, "offered_only": 0.01, "hidden_required": 0.01,
            "exact_required": 0.99,
        ]
        XCTAssertNotNil(VerifiedVisualGoal(proof: proof, observation: fresh,
            model: "jev-1.14.0", scores: scores))
        for key in ["hidden_required", "offered_only", "completed", "evidence_visible", "kind_supported"] {
            var contradictory = scores
            contradictory[key] = ["hidden_required", "offered_only"].contains(key) ? 0.99 : 0.01
            XCTAssertNil(VerifiedVisualGoal(proof: proof, observation: fresh,
                model: "jev-1.14.0", scores: contradictory), key)
        }
    }

    func testC1ScrollNeedsIndependentAuthorizationAcrossLanes() async throws {
        let task = decisionObservation().task
        for operation: VisualOperation in [.scrollUp, .scrollDown] {
            for candidate: String? in [nil, "element_1"] {
                let questions = JevVisualDecision.groundQuestions(task: task,
                    operation: operation, nativeCandidateID: candidate)
                XCTAssertNotNil(questions["authorized"], "\(operation) \(candidate ?? "pixels")")
            }
            let questions = Dictionary(uniqueKeysWithValues:
                JevVisualDecision.openQuestions(task: task, elementID: "element_1",
                                               editing: false, operation: operation)
                    .map { ("open_element_1__" + $0.key, $0.value) })
            let (rejected, _) = try await VisualModel(.unauthorized)
                .infer(.object([:]), questions, [:])
            XCTAssertFalse(JevVisualDecision.openLaneCleared(primary: rejected, id: "element_1",
                denyCount: 0, operation: operation, needsSubject: false, subject: nil))
            let (allowed, _) = try await VisualModel(.openLane)
                .infer(.object([:]), questions, [:])
            XCTAssertTrue(JevVisualDecision.openLaneCleared(primary: allowed, id: "element_1",
                denyCount: 0, operation: operation, needsSubject: false, subject: nil))
        }
    }

    func testC1IdenticalPixelsCannotHideChangedDocument() async throws {
        var original = try visualObservation()
        let document = NativeDocumentSubject(window: window, fingerprint: Data(repeating: 1, count: 32))
        original.axSnapshot?.nativeDocument = document
        let box = try JevBox(top: 0.2, bottom: 0.4, left: 0.2, right: 0.4)
        let proof = try XCTUnwrap(VisualGoalProof(observation: original, kind: .status,
            box: box, presence: 0.99, boxConfidence: nil, probabilities: [:]))
        var fresh = original
        let frame = try VisualFrame.decode(result(changes: ["capture_id": .string("changed-document")]),
            window: window, session: "test-session")
        fresh.screenshot = CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame)
        fresh.visualAnchor = original.screenshot?.frame
        fresh.visualAnchorDocument = document
        fresh.axSnapshot?.nativeDocument = NativeDocumentSubject(
            window: window, fingerprint: Data(repeating: 2, count: 32))
        XCTAssertEqual(proof.anchor.imageHash, frame.imageHash)
        let model = VisualModel(.goal)
        do {
            let verified = try await JevVisualDecision.verifyGoal(proof, observation: fresh,
                model: "jev-1.14.0", infer: { state, questions, images in
                    try await model.infer(state, questions, images)
                })
            XCTAssertNil(verified, "Native document identity must dominate identical screen bytes")
        } catch VisualGoalFailure.subjectUnverified {}
        let decision = try await visualDecision(VisualModel(.click), fresh)
        guard case .blocked = decision else {
            return XCTFail("Changed document admitted an action: \(decision)")
        }
    }

    func testC1ExactNativeFactsPreserveWhitespaceAndUnicode() throws {
        for (literal, actual) in [("\nC1", "C1"), ("a\n\nb", "a\nb"), ("é", "e\u{301}")] {
            var observation = try visualObservation()
            observation.task.values["literal"] = literal
            observation.axSnapshot = AXSnapshot(windowTitle: "Synthetic", snapshotID: "literal",
                elements: [AXElement(index: 1, role: "AXTextField", label: "Draft", value: actual, actions: [])],
                treeMarkdown: "", goalContextComplete: true)
            XCTAssertFalse(VisualGoalProof.nativeExactEvidence(in: observation))
            observation.axSnapshot?.elements[0].value = literal
            XCTAssertTrue(VisualGoalProof.nativeExactEvidence(in: observation))
        }
    }

    func testC1IdenticalPixelsStillNeedSubjectEvidence() async throws {
        let original = try visualObservation()
        let proof = try XCTUnwrap(VisualGoalProof(observation: original, kind: .status,
            box: JevBox(top: 0.2, bottom: 0.4, left: 0.2, right: 0.4),
            presence: 0.99, boxConfidence: nil, probabilities: [:]))
        var fresh = original
        let frame = try VisualFrame.decode(result(changes: ["capture_id": .string("same-pixels")]),
            window: window, session: "test-session")
        fresh.screenshot = CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame)
        let model = VisualModel(.changedSubject)
        do {
            let verified = try await JevVisualDecision.verifyGoal(proof, observation: fresh,
                model: "jev-1.14.0", infer: { state, questions, images in
                    try await model.infer(state, questions, images)
                })
            XCTAssertNil(verified)
        } catch VisualGoalFailure.subjectUnverified {}
        let requests = await model.requests
        XCTAssertNotNil(requests.first?["same_subject"])
    }

    func testC1NativeLiteralPresenceKeepsRawJudgment() async throws {
        var observation = try visualObservation()
        observation.task.goal = "Enter C1 literal in Draft"
        observation.task.values["literal"] = "C1 literal"
        observation.axSnapshot = AXSnapshot(windowTitle: "Synthetic", snapshotID: "literal",
            elements: [AXElement(index: 1, role: "AXTextField", label: "Draft", value: "C1 literal", actions: [])],
            treeMarkdown: "", goalContextComplete: true)
        let decision = try await visualDecision(VisualModel(.nativeLiteralGoalLowPresence), observation)
        guard case .act(let request) = decision, let proof = request.visualVerification else {
            return XCTFail("Native literal facts should remain eligible for independent verification")
        }
        XCTAssertEqual(proof.kind, .exactText)
        XCTAssertEqual(proof.presence, 0.01, "A native fact must not invent a model probability")
        XCTAssertTrue(proof.hasNativeExactEvidence(observation))
    }

    func testC1ReferentCannotEraseConflictingIdentityMatches() async throws {
        let decision = try await visualDecision(
            VisualModel(.referentAmbiguous, nativeSelection: "element_2"), referentObservation())
        guard case .blocked = decision else {
            return XCTFail("A referent pick erased multiple independently matched targets")
        }
    }

    func testC1MultipleLiteralsRequirePermissionForSelectedValue() async throws {
        var observation = try nativeObservation(tools: ["set_value"], elements: [AXElement(
            index: 1, token: "s00000001:1", role: "AXTextArea", label: "Body",
            value: "existing text", frame: CGRect(x: 110, y: 210, width: 80, height: 30), actions: [])])
        observation.task.values = ["a": "first literal", "b": "second literal"]
        let model = VisualModel(.replaceLane)
        let decision = try await visualDecision(model, observation)
        guard case .act = decision else { return XCTFail("A fully grounded edit was lost") }
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(requests.last?["native_element_1__authorized"],
                        "Authorization must bind the actual selected literal")
    }

    private func nativeObservation(tools: Set<String> = ["click"],
                                   elements: [AXElement]? = nil) throws -> TaskObservation {
        var raw = try result()
        raw.capturedElementTools = tools
        let frame = try VisualFrame.decode(raw, window: window, session: "test-session")
        var observation = decisionObservation(elements: elements ?? [AXElement(
            index: 1, token: "s00000001:1", role: "AXButton", label: "Search",
            value: nil, frame: CGRect(x: 125, y: 225, width: 45, height: 45), actions: ["AXPress"])])
        observation.screenshot = CapturedImage(captureID: frame.captureID,
            data: frame.asset.data, frame: frame)
        return observation
    }

    func testD16BoundPresenceDoesNotUseAnUnboundGuess() async throws {
        let model = VisualModel(.unboundPresence)
        let decision = try await visualDecision(model, visualObservation())
        guard case .act(let request) = decision else {
            return XCTFail("An unbound presence guess blocked the concrete target: \(decision)")
        }
        XCTAssertEqual(request.effect, .tool)
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests.first?["target_present"])
        XCTAssertNotNil(requests.last?["target_present"])
    }

    func testD16UncertainNativeMatchKeepsTheFullyProvenPixelFallback() async throws {
        let model = VisualModel(.nativePresenceUncertain)
        let decision = try await visualDecision(model, nativeObservation())
        guard case .act(let request) = decision else {
            return XCTFail("An uncertain candidate match removed the pixel fallback: \(decision)")
        }
        XCTAssertNil(request.args["element_token"])
        XCTAssertNotNil(request.args["x"])
    }

    private func d16NativeChooser(id: String = "e1", coverageMissing: Bool = false) -> DriveLoop.Choose {
        JevChooser.make(model: "jev-1.14.0") { _, questions in
            var answers: [String: Any] = [:]
            for (name, question) in questions {
                if case .choice(_, let criteria) = question {
                    let selected = name == "goal_fact" ? "none" : id
                    let selectedProbability = criteria.count == 1 ? 1.0 : 0.68
                    let probabilities = Dictionary(uniqueKeysWithValues: criteria.keys.map {
                        ($0, $0 == selected ? selectedProbability
                            : 0.32 / Double(max(1, criteria.count - 1)))
                    })
                    answers[name] = ["type": "choice", "choice": selected,
                                     "confidence": selectedProbability, "probabilities": probabilities]
                } else {
                    let value = name == "done" || name.hasPrefix("goal_") ? 0.01
                        : coverageMissing && (name == "applicable" || name.hasPrefix("action_support_")) ? 0.01 : 0.99
                    answers[name] = ["type": "noul", "noul": value]
                }
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "model": "jev-1.14.0", "answers": answers,
            ])
            return (try JSONDecoder().decode(SystemOneResponse.self, from: body), 1)
        }
    }

    func testD16VisualFallbackRetainsTheNativeOperation() async throws {
        var observation = decisionObservation(elements: [searchElement()])
        observation.axSnapshot?.goalContextComplete = false
        observation.task.values = ["a": "unused one", "b": "unused two", "text": "owned literal"]

        let model = VisualModel(.typing)
        let visual = JevChooser.makeVisual(model: "jev-1.14.0") { state, questions, assets in
            try await model.infer(state, questions, assets)
        }
        var pending = observation
        let decider = JevDecider(choose: d16NativeChooser(), visualChoose: visual)
        let first = try await decider.nextStep(pending)
        guard case .act(let refresh) = first, refresh.effect == .reobserve else {
            return XCTFail("Native uncertainty did not request grounding")
        }
        pending.stepIndex = 1
        pending.history = [.init(stepIndex: 0, echo: .reobserve, summary: refresh.summary)]
        let frame = try VisualFrame.decode(result(), window: window, session: "test-session")
        pending.screenshot = CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame)
        let decision = try await decider.nextStep(pending)
        guard case .act(let request) = decision, request.tool == "click" else {
            return XCTFail("Bound click proposal was not retained: \(decision)")
        }
        XCTAssertNil(request.visualTarget?.literal)
        let state = await model.states.first
        XCTAssertEqual(state?["semantic_proposal"]?["operation"], .string("click"))
        XCTAssertNotNil(state?["semantic_proposal"])

        let rejecting = VisualModel(.rejectsProposal)
        let rejectVisual = JevChooser.makeVisual(model: "jev-1.14.0") { state, questions, assets in
            try await rejecting.infer(state, questions, assets)
        }
        let rejectDecider = JevDecider(choose: d16NativeChooser(), visualChoose: rejectVisual)
        var second = observation
        let again = try await rejectDecider.nextStep(second)
        guard case .act(let againRequest) = again, againRequest.effect == .reobserve else {
            return XCTFail("Native uncertainty did not request grounding")
        }
        second.stepIndex = 1
        second.history = [.init(stepIndex: 0, echo: .reobserve, summary: againRequest.summary)]
        second.screenshot = pending.screenshot
        // A confidence miss earns bounded fresh-capture retries; the
        // rejected target must still block after they are exhausted.
        for attempt in 0...3 {
            let outcome = try await rejectDecider.nextStep(second)
            if attempt < 3 {
                guard case .act(let retry) = outcome, retry.effect == .reobserve else {
                    return XCTFail("Retry \(attempt) did not request a fresh capture: \(outcome)")
                }
                second.stepIndex += 1
                second.history.append(.init(stepIndex: second.stepIndex - 1,
                                            echo: .reobserve, summary: retry.summary))
            } else {
                guard case .blocked(let reason) = outcome else {
                    return XCTFail("A rejected pictured target still actuated: \(outcome)")
                }
                XCTAssertEqual(reason, .safety(JevVisualDecision.unverifiableVisualReason))
            }
        }
    }

    func testD95VerifyRejectedAdvisoryResolvesThePickedOperation() async throws {
        var observation = decisionObservation(elements: [searchElement()])
        observation.axSnapshot?.goalContextComplete = false

        let model = VisualModel(.verifyRejectedScroll)
        let visual = JevChooser.makeVisual(model: "jev-1.14.0") { state, questions, assets in
            try await model.infer(state, questions, assets)
        }
        var pending = observation
        let decider = JevDecider(choose: d16NativeChooser(), visualChoose: visual)
        let first = try await decider.nextStep(pending)
        guard case .act(let refresh) = first, refresh.effect == .reobserve else {
            return XCTFail("Native uncertainty did not request grounding")
        }
        pending.stepIndex = 1
        pending.history = [.init(stepIndex: 0, echo: .reobserve, summary: refresh.summary)]
        let frame = try VisualFrame.decode(result(), window: window, session: "test-session")
        pending.screenshot = CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame)
        let decision = try await decider.nextStep(pending)
        guard case .act(let request) = decision, request.tool == "scroll" else {
            return XCTFail("A verify-rejected advisory proposal did not yield to the picked scroll: \(decision)")
        }
        XCTAssertEqual(request.args["direction"], .string("down"))
        XCTAssertEqual(request.visualTarget?.operation, .scrollDown)
        // The rejected guess must not constrain grounding: the independent
        // operation pick — not the advisory proposal — drove the dispatch.
        let primary = await model.requests.first
        let state = await model.states.first
        XCTAssertNotNil(primary?["operation_alternative"])
        XCTAssertEqual(state?["semantic_proposal"]?["operation"], .string("click"))
    }

    func testD16SemanticUncertaintyDoesNotRequestPixelsFromCompleteAX() async throws {
        for coverageMissing in [false, true] {
            let decider = JevDecider(choose: d16NativeChooser(coverageMissing: coverageMissing), visualChoose: { _ in
                XCTFail("This test only requests evidence, it does not yet provide a capture")
                return .blocked(reason: .decider("unexpected image request"))
            })
            var observation = decisionObservation(elements: [searchElement()])
            let decision = try await decider.nextStep(observation)
            guard case .act(let request) = decision, request.effect == .reobserve else {
                return XCTFail("Expected bounded recovery")
            }
            observation.stepIndex = 1
            observation.history = [.init(stepIndex: 0, echo: .reobserve, summary: request.summary)]
            let needs = await decider.needsScreenshot(for: observation)
            XCTAssertEqual(needs, coverageMissing,
                "A complete AX tree may omit the requested control; selection ambiguity alone is different")
        }
    }

    func testD16FallbackRejectsChangedLiteralKeyAndReplacementOperation() async throws {
        for (tool, args, scenario) in [
            ("type_text", ["text": JSONValue.string("expected literal")], VisualModel.Scenario.typing),
            ("set_value", ["value": .string("expected literal")], .typing),
            ("press_key", ["key": .string("escape")], .keyCommand),
        ] {
            let model = VisualModel(scenario)
            let visual = JevChooser.makeVisual(model: "jev-1.14.0") {
                try await model.infer($0, $1, $2)
            }
            let decider = JevDecider(choose: d16NativeChooser(id: "d16"), extras: { _ in
                .init(candidates: [.init(id: "d16", description: "owned operation",
                    kind: .request(.init(effect: .tool, tool: tool, args: args, summary: "owned operation")))])
            }, visualChoose: visual)
            var observation = decisionObservation(elements: [searchElement()])
            observation.axSnapshot?.goalContextComplete = false
            observation.task.values = ["a": "expected literal", "b": "unused", "text": "wrong literal"]
            let first = try await decider.nextStep(observation)
            guard case .act(let refresh) = first, refresh.effect == .reobserve else {
                return XCTFail("Expected bounded recovery for \(tool)")
            }
            observation.stepIndex = 1
            observation.history = [.init(stepIndex: 0, echo: .reobserve, summary: refresh.summary)]
            let frame = try VisualFrame.decode(result(), window: window, session: "test-session")
            observation.screenshot = .init(captureID: frame.captureID, data: frame.asset.data, frame: frame)
            let decision = try await decider.nextStep(observation)
            if case .act(let request) = decision {
                XCTAssertNotEqual(request.effect, .tool, "Changed \(tool) argument reached input")
            }
        }
    }

    func testD16PendingProposalCannotSurviveChangedTaskOrInterveningStep() async throws {
        for shape in ["task", "window", "document", "actuation", "skipped-step"] {
            let model = VisualModel(.click)
            let visual = JevChooser.makeVisual(model: "jev-1.14.0") {
                try await model.infer($0, $1, $2)
            }
            let decider = JevDecider(choose: d16NativeChooser(), visualChoose: visual)
            var observation = decisionObservation(elements: [searchElement()])
            observation.axSnapshot?.goalContextComplete = false
            observation.axSnapshot?.nativeDocument = .init(window: window, fingerprint: Data("original".utf8))
            let first = try await decider.nextStep(observation)
            guard case .act(let refresh) = first else { return XCTFail("Missing recovery") }
            observation.stepIndex = shape == "skipped-step" ? 2 : 1
            observation.history = [.init(stepIndex: 0,
                echo: shape == "actuation" ? .act : .reobserve, summary: refresh.summary,
                actuated: shape == "actuation")]
            if shape == "task" { observation.task.goal = "Open Another Subject" }
            if shape == "document" {
                observation.axSnapshot?.nativeDocument = .init(window: window, fingerprint: Data("other".utf8))
            }
            let nextWindow = shape == "window" ? Jarvis.WindowRef(pid: 7, windowID: 43) : window
            observation.task.window = nextWindow
            let frame = try VisualFrame.decode(result(changes: [
                "window_id": .number(Double(nextWindow.windowID)),
            ]), window: nextWindow, session: "test-session")
            observation.screenshot = .init(captureID: frame.captureID, data: frame.asset.data, frame: frame)
            let decision = try await decider.nextStep(observation)
            if case .act(let request) = decision {
                XCTAssertNotEqual(request.effect, .tool, shape)
            }
            let requests = await model.requests
            XCTAssertTrue(requests.isEmpty, shape)
        }
    }

    func testNativeImageSelectionKeepsTokenAndCaptureWithoutPixels() async throws {
        let observation = try nativeObservation()
        let frame = try XCTUnwrap(observation.screenshot?.frame)
        XCTAssertEqual(frame.snapshotID, "s00000001")
        XCTAssertEqual(frame.capturedElementTools, ["click"])
        let model = VisualModel(.nativeMatch)
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else { return XCTFail("native target not selected") }
        XCTAssertEqual(request.args["capture_id"], .string("capture-synthetic"))
        XCTAssertEqual(request.args["element_token"], .string("s00000001:1"))
        XCTAssertNil(request.args["x"])
        XCTAssertNil(request.args["y"])
        let target = try XCTUnwrap(request.visualTarget)
        XCTAssertTrue(target.validates(request, observation: observation))
        var replaced = observation
        replaced.axSnapshot?.elements[0].token = "s00000002:1"
        XCTAssertFalse(target.validates(request, observation: replaced))
        var changed = request
        changed.args["x"] = .number(1)
        XCTAssertFalse(target.validates(changed, observation: observation))
        let states = await model.states
        XCTAssertEqual(states.count, 2, "Native matching shares independent grounding, not a new perception loop")
        XCTAssertNotNil(states[1]["native_candidates"]?["element_1"])
    }

    func testNativeGroundingSuppliesNodePictureWithoutReplacingFullScene() async throws {
        let observation = try nativeObservation()
        let frame = try XCTUnwrap(observation.screenshot?.frame)
        let model = VisualModel(.nativeMatch)
        _ = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        let states = await model.states
        let assets = await model.assets
        let requests = await model.requests
        XCTAssertEqual(states.count, 2)
        let full = try XCTUnwrap(states[1]["current_image"]?.string)
        XCTAssertEqual(assets[1][full]?.data, frame.asset.data)
        let picture = try XCTUnwrap(states[1]["native_candidates"]?["element_1"]?["image"]?.string)
        XCTAssertNotEqual(picture, full)
        let detail = try XCTUnwrap(assets[1][picture])
        XCTAssertGreaterThanOrEqual(detail.width, 280)
        XCTAssertGreaterThanOrEqual(detail.height, 280)
        guard case .noul = requests[1]["native_element_1__match"] else {
            return XCTFail("Missing pictured-candidate match judgment")
        }
        XCTAssertEqual(states[1]["native_candidates"]?["element_1"]?["image"], .string(picture))
        XCTAssertEqual(states[1]["native_candidates"]?["element_1"]?["label"], .string("Search"))
    }

    func testClickAuthorizationDoesNotInheritMissingLiteralPremise() async throws {
        let model = VisualModel(.click)
        _ = try await JevVisualDecision.decide(try visualObservation(), model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        let requests = await model.requests
        guard case .noul(let instructions, _) = requests[1]["authorized"] else {
            return XCTFail("Missing independent authorization judgment")
        }
        XCTAssertFalse(instructions.contains("literal"))
        XCTAssertTrue(instructions.contains("history"))
        XCTAssertTrue(instructions.contains("goal"))
    }

    func testTypingAuthorizationRetainsCallerLiteralAndMissingValueRules() async throws {
        let model = VisualModel(.missingText)
        _ = try await JevVisualDecision.decide(try visualObservation(), model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        let requests = await model.requests
        guard case .noul(let instructions, _) = requests[1]["authorized"] else {
            return XCTFail("Missing typing authorization judgment")
        }
        XCTAssertTrue(instructions.contains("literal"))
        XCTAssertTrue(instructions.contains("missing value"))
        XCTAssertTrue(instructions.contains("not permission"))
    }

    func testControlCriteriaDefineTheExistingClassesWithoutInventingNewOnes() throws {
        let questions = JevVisualDecision.groundQuestions(task: decisionObservation().task)
        guard case .choice(_, let criteria) = questions["control"] else {
            return XCTFail("Missing control classification")
        }
        XCTAssertEqual(Set(criteria.keys), Set(VisualControl.allCases.map(\.rawValue)))
        XCTAssertTrue(try XCTUnwrap(criteria["toggle"] ?? nil).contains("switch"))
        XCTAssertTrue(try XCTUnwrap(criteria["ordinary"] ?? nil).contains("button"))
        XCTAssertTrue(try XCTUnwrap(criteria["unknown"] ?? nil).contains("identified"))
    }

    private func patternedFrame(width: Int, height: Int) throws -> VisualFrame {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = x < width / 2 ? 255 : 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = x < width / 2 ? 0 : 255
                pixels[offset + 3] = 255
            }
        }
        let raw = try result(width: width, height: height)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return try VisualFrame.decode(CuaToolResult(structured: raw.structured, content: [.object([
            "type": .string("image"), "mimeType": .string("image/png"),
            "data": .string(data.base64EncodedString()),
        ])]), window: window, session: "test-session")
    }

    func testNativePicturesUseTheCorrectRegionAndRetainOriginalBytes() throws {
        let frame = try patternedFrame(width: 560, height: 280)
        let original = frame.asset.data
        for (rect, red) in [
            (CGRect(x: 110, y: 210, width: 30, height: 20), true),
            (CGRect(x: 300, y: 210, width: 30, height: 20), false),
        ] {
            let picture = try frame.nativePicture(in: rect)
            XCTAssertEqual(picture.width, 280)
            XCTAssertEqual(picture.height, 280)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: picture.data))
            let color = try XCTUnwrap(bitmap.colorAt(x: 140, y: 140)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(red ? color.redComponent : color.blueComponent, 0.9)
            XCTAssertLessThan(red ? color.blueComponent : color.redComponent, 0.1)
        }
        XCTAssertEqual(frame.asset.data, original)
    }

    func testNativePictureAccountsForSourcePaddingWithoutUsingPaddingAsContent() throws {
        let frame = try patternedFrame(width: 180, height: 120)
        let picture = try frame.nativePicture(in: CGRect(x: 160, y: 210, width: 20, height: 20))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: picture.data))
        let color = try XCTUnwrap(bitmap.colorAt(x: 140, y: 140)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.9)
        XCTAssertLessThan(color.redComponent, 0.1)
    }

    func testNativePictureRejectsInvalidOrForeignRectangles() throws {
        let frame = try patternedFrame(width: 280, height: 280)
        for rect in [CGRect.null, .infinite, .zero,
                     CGRect(x: 90, y: 210, width: 20, height: 20),
                     CGRect(x: 300, y: 400, width: 20, height: 20)] {
            XCTAssertThrowsError(try frame.nativePicture(in: rect)) { error in
                guard case VisualCaptureError.outsideImage = error else {
                    return XCTFail("Unexpected native picture refusal: \(error)")
                }
            }
        }
    }

    func testNativePictureRejectsReplacementBytesUnderTheOriginalFrameHash() throws {
        let original = try patternedFrame(width: 280, height: 280)
        let replaced = VisualFrame(
            asset: try JevImageAsset(data: image(width: 280, height: 280, marker: 7), format: .png),
            captureID: original.captureID, window: original.window, session: original.session,
            bounds: original.bounds, driverSize: original.driverSize, contentRect: original.contentRect,
            generation: original.generation, imageHash: original.imageHash)
        XCTAssertThrowsError(try replaced.nativePicture(in: CGRect(x: 110, y: 210, width: 20, height: 20))) {
            guard case VisualCaptureError.invalidCapture = $0 else {
                return XCTFail("Replacement bytes were not rejected as an invalid capture")
            }
        }
    }

    func testNativeTokenUsesItsOwnTargetProofNotAnUnusedPixelPoint() async throws {
        let observation = try nativeObservation()
        let model = VisualModel(.nativePixelUncertain)
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else { return XCTFail("Named native target was judged as a pixel") }
        XCTAssertEqual(request.args["element_token"], .string("s00000001:1"))
        XCTAssertEqual(request.args["capture_id"], .string("capture-synthetic"))
        XCTAssertNil(request.args["x"])
        XCTAssertNil(request.args["y"])
        XCTAssertEqual(request.visualTarget?.location, 1)
        XCTAssertEqual(request.visualTarget?.authorization, 0.99)
        XCTAssertTrue(try XCTUnwrap(request.visualTarget).validates(request, observation: observation))
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2, "Both references share the existing grounding request")
        guard case .noul(let nativeInstructions, _) = requests[1]["native_element_1__authorized"] else {
            return XCTFail("Missing native-object authorization")
        }
        XCTAssertTrue(nativeInstructions.contains("`native_candidates.element_1`"))
        XCTAssertFalse(nativeInstructions.contains("box center"))
        XCTAssertNotNil(requests[1]["authorized"], "Original pixel proof is not removed")
    }

    func testOpenLaneSettlesDecisiveNativeWinnerInOneCall() async throws {
        let observation = try nativeObservation()
        let model = VisualModel(.openLane)
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else {
            return XCTFail("Decisive open winner did not act: \(result)")
        }
        XCTAssertEqual(request.args["element_token"], .string("s00000001:1"))
        XCTAssertNil(request.args["x"])
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1, "Pictured decisive winner needs no second request")
        guard case .noul(let instructions, _) = requests[0]["open_element_1__match"] else {
            return XCTFail("Missing op-agnostic identity judgment")
        }
        XCTAssertTrue(instructions.contains("open_candidates.element_1"))
        XCTAssertNotNil(requests[0]["open_element_1__authorized"],
                        "Pictured winner carries its policy set in the primary call")
    }

    func testOpenLaneReplaceModeDispatchesSetValue() async throws {
        var observation = try nativeObservation(tools: ["set_value"], elements: [AXElement(
            index: 1, token: "s00000001:1", role: "AXTextArea", label: "Body",
            value: "existing text", frame: CGRect(x: 110, y: 210, width: 80, height: 30),
            actions: [])])
        observation.task.values = ["z": "replacement text"]
        let model = VisualModel(.replaceLane)
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else {
            return XCTFail("Replace-mode winner did not act: \(result)")
        }
        XCTAssertEqual(request.tool, "set_value")
        XCTAssertEqual(request.args["value"], .string("replacement text"))
        XCTAssertEqual(request.args["element_token"], .string("s00000001:1"))
        XCTAssertNil(request.args["element_index"])
        XCTAssertNil(request.args["capture_id"])
        XCTAssertNil(request.args["delivery_mode"])
        XCTAssertNil(request.args["x"])
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1, "Replace winner settles in the primary call")
        XCTAssertNotNil(requests[0]["open_element_1__text_mode"],
                        "Editing winner carries the insert/replace judgment")
    }

    private func referentObservation() throws -> TaskObservation {
        try nativeObservation(elements: [
            AXElement(index: 1, token: "s00000001:1", role: "AXButton", label: "Clear",
                      value: nil, frame: CGRect(x: 110, y: 280, width: 40, height: 40),
                      actions: ["AXPress"]),
            AXElement(index: 2, token: "s00000001:2", role: "AXButton", label: "3",
                      value: nil, frame: CGRect(x: 160, y: 280, width: 40, height: 40),
                      actions: ["AXPress"]),
        ])
    }

    func testOpenReferentPickBindsIndecisiveMatchWinner() async throws {
        let model = VisualModel(.referentPick, nativeSelection: "element_2")
        let result = try await JevVisualDecision.decide(try referentObservation(),
            model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else {
            return XCTFail("A decisive referent pick failed to bind its element: \(result)")
        }
        XCTAssertEqual(request.args["element_token"], .string("s00000001:2"))
        let requests = await model.requests
        guard case .choice(_, let criteria)? = requests.first?["open_referent"] else {
            return XCTFail("The referent selection was not asked in the primary call")
        }
        XCTAssertTrue(criteria.keys.contains("element_2"))
        XCTAssertTrue(criteria.keys.contains("none"))
        XCTAssertNotNil(requests.dropFirst().first?["native_element_2__match"],
                        "An uncertain referent needs its own supported identity before actuation")
    }

    func testOpenReferentPickRejectedMatchCannotBind() async throws {
        let model = VisualModel(.referentVeto, nativeSelection: "element_2")
        let result = try await JevVisualDecision.decide(try referentObservation(),
            model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else {
            return XCTFail("The referent-veto run did not fall back to the pixel lane: \(result)")
        }
        XCTAssertNil(request.args["element_token"],
                     "A decisively rejected identity match must veto the referent pick")
        XCTAssertNotNil(request.args["x"])
    }

    func testNativePolicyFailureCannotEscapeThroughOptimisticPixelAnswers() async throws {
        let observation = try nativeObservation()
        let model = VisualModel(.nativeUnauthorized)
        let unauthorized = try await JevVisualDecision.decide(observation,
            model: "jev-1.14.0",
            infer: { state, questions, images in
                try await model.infer(state, questions, images) })
        if case .act(let request) = unauthorized, request.effect == .tool {
            XCTFail("Native identity substituted for a rejected authorization")
        }
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2, "Unchanged authorization evidence must not be redrawn")
        // Deny hits and protected consequences stay live gates.
        for (scenario, reason): (VisualModel.Scenario, String) in [
            (.nativeDenied, "The visual input failed its scope, location, permission, or deny checks."),
            (.nativeProtected, "The visual input failed its scope, location, permission, or deny checks."),
        ] {
            var observation = try nativeObservation()
            observation.task.deny = ["Do not activate the other control"]
            let model = VisualModel(scenario)
            let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
                infer: { state, questions, images in try await model.infer(state, questions, images) })
            XCTAssertEqual(result, .blocked(reason: .safety(reason)), "\(scenario)")
        }
    }

    func testMissingNativeJudgmentsDoNotBorrowPixelPermission() async throws {
        let model = VisualModel(.nativeMissing)
        let result = try await JevVisualDecision.decide(try nativeObservation(), model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        XCTAssertEqual(result, .blocked(reason: .safety(JevVisualDecision.unverifiableVisualReason)))
    }

    func testWeakNativeIdentityCannotBorrowStrongNativeJudgmentsForPixels() async throws {
        let model = VisualModel(.nativeWeakIdentityPixelWeak)
        let result = try await JevVisualDecision.decide(try nativeObservation(), model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        XCTAssertEqual(result, .blocked(reason: .safety(JevVisualDecision.unverifiableVisualReason)))
    }

    func testUncertainNativeIdentityKeepsTheFullyProvenPixelFallback() async throws {
        let observation = try nativeObservation()
        let model = VisualModel(.nativeWeakIdentity)
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else { return XCTFail("Proven pixel fallback disappeared") }
        XCTAssertNil(request.args["element_token"])
        XCTAssertNotNil(request.args["x"])
        XCTAssertEqual(request.args["capture_id"], .string("capture-synthetic"))
    }

    private func overlappingNativeObservation(count: Int) throws -> TaskObservation {
        var observation = try nativeObservation()
        observation.axSnapshot?.elements = (1...count).map { index in
            AXElement(index: index, token: "s00000001:\(index)", role: "AXButton",
                label: "Control \(index)", value: nil,
                frame: CGRect(x: 125, y: 225, width: 45, height: 45), actions: ["AXPress"])
        }
        observation.task.deny = ["Do not activate a forbidden control"]
        return observation
    }

    func testSelectedNativeObjectCannotBorrowASiblingsPermission() async throws {
        let observation = try overlappingNativeObservation(count: 2)
        let model = VisualModel(.nativeUnauthorized, nativeSelection: "element_2")
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        if case .act(let request) = result, request.effect == .tool {
            XCTFail("The selected object's rejected permission was replaced by a sibling's permission")
        }
    }

    func testChosenNativeIdentityCannotBorrowAnAtLeastOneMatchForASibling() async throws {
        let observation = try overlappingNativeObservation(count: 2)
        let model = VisualModel(.nativeChosenIdentityWeak, nativeSelection: "element_2")
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else { return XCTFail("Independent pixel proof disappeared") }
        XCTAssertNil(request.args["element_token"])
        XCTAssertNotNil(request.args["x"])
    }

    func testWeakChosenNativeIdentityAndWeakPixelLocationRefuseBothRoutes() async throws {
        let model = VisualModel(.nativeChosenIdentityWeakPixelWeak)
        let result = try await JevVisualDecision.decide(try nativeObservation(), model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        XCTAssertEqual(result, .blocked(reason: .safety(JevVisualDecision.unverifiableVisualReason)))
    }

    func testUnusedNativeSiblingJudgmentsDoNotAuthorizeOrBlockTheSelectedObject() async throws {
        let observation = try overlappingNativeObservation(count: 2)
        let model = VisualModel(.nativeIgnoredSiblingUnsafe, nativeSelection: "element_2")
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else { return XCTFail("Unused sibling changed selected authority") }
        XCTAssertEqual(request.args["element_token"], .string("s00000001:2"))
        XCTAssertTrue(try XCTUnwrap(request.visualTarget).validates(request, observation: observation))
    }

    func testEveryPicturedNativeCandidateGetsItsOwnCompleteJudgmentGroup() async throws {
        let observation = try overlappingNativeObservation(count: 9)
        let model = VisualModel(.nativeMatch, nativeSelection: "element_9")
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else { return XCTFail("Native choices were cut off") }
        XCTAssertEqual(request.args["element_token"], .string("s00000001:9"))
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2)
        for index in 1...9 {
            for question in ["match", "authorized", "protected", "deny_0"] {
                XCTAssertNotNil(requests[1]["native_element_\(index)__\(question)"])
            }
        }
    }

    func testTwoConfidentNativeMatchesRefuseAmbiguousTargetSelection() async throws {
        let observation = try overlappingNativeObservation(count: 2)
        let model = VisualModel(.nativeAmbiguous, nativeSelection: "element_1")
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        XCTAssertEqual(result, .blocked(reason: .safety(JevVisualDecision.unverifiableVisualReason)))
    }

    func testPicturedCandidateClickOmitsRedundantOrAmbiguousJudgments() async throws {
        var observation = try nativeObservation()
        observation.task.deny = ["Do not activate a forbidden control"]
        let model = VisualModel(.nativeMatch)
        _ = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        let requests = await model.requests
        for question in ["match", "authorized", "protected", "deny_0"] {
            XCTAssertNotNil(requests[1]["native_element_1__\(question)"], question)
        }
        for question in ["native_element", "native_matches", "native_element_1__identity",
                         "native_element_1__located", "native_element_1__target_present",
                         "native_element_1__control", "native_element_1__editable_obstruction"] {
            XCTAssertNil(requests[1][question], question)
        }
    }

    private func nativeTypingObservation() throws -> TaskObservation {
        var raw = try result()
        raw.capturedElementTools = ["type_text"]
        let frame = try VisualFrame.decode(raw, window: window, session: "test-session")
        var observation = decisionObservation(elements: [AXElement(
            index: 1, token: "s00000001:1", role: "AXTextField", label: "Search field",
            value: nil, frame: CGRect(x: 125, y: 225, width: 45, height: 45), actions: [])])
        observation.task.values = ["a": "unused one", "b": "unused two", "text": "owned literal"]
        observation.screenshot = CapturedImage(captureID: frame.captureID,
            data: frame.asset.data, frame: frame)
        return observation
    }

    func testTypeTextOnPicturedFieldKeepsEditableClassificationAndToken() async throws {
        let observation = try nativeTypingObservation()
        let model = VisualModel(.typing)
        let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
            infer: { state, questions, images in try await model.infer(state, questions, images) })
        guard case .act(let request) = result else {
            return XCTFail("Editable pictured field was not selected: \(result)")
        }
        XCTAssertEqual(request.args["element_token"], .string("s00000001:1"))
        XCTAssertEqual(request.args["text"], .string("owned literal"))
        let requests = await model.requests
        XCTAssertNotNil(requests[1]["native_element_1__match"])
        XCTAssertNotNil(requests[1]["native_element_1__control"])
        XCTAssertNotNil(requests[1]["native_element_1__editable_obstruction"])
    }

    func testTypeTextOnPicturedFieldRefusesCredentialOrUncertainEditable() async throws {
        for (scenario, reason) in [
            (VisualModel.Scenario.nativeTypingCredential,
             "The visual target is not a confirmed non-secure editable field."),
            (.nativeTypingEditableUncertain, JevVisualDecision.unverifiableVisualReason),
        ] {
            let observation = try nativeTypingObservation()
            let model = VisualModel(scenario)
            let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
                infer: { state, questions, images in try await model.infer(state, questions, images) })
            XCTAssertEqual(result, .blocked(reason: .safety(reason)), "\(scenario)")
        }
    }

    func testNativeSelectionNeedsCapabilitySameSnapshotAndSemanticMatch() async throws {
        for condition in ["missing capability", "wrong tool", "foreign snapshot", "foreign token", "semantic mismatch"] {
            var observation = try nativeObservation(tools: condition == "missing capability" ? []
                : condition == "wrong tool" ? ["scroll"] : ["click"])
            if condition == "foreign snapshot" { observation.axSnapshot?.snapshotID = "s00000002" }
            if condition == "foreign token" { observation.axSnapshot?.elements[0].token = "s00000002:1" }
            let model = VisualModel(condition == "semantic mismatch" ? .nativeMismatch : .nativeMatch)
            let result = try await JevVisualDecision.decide(observation, model: "jev-1.14.0",
                infer: { state, questions, images in try await model.infer(state, questions, images) })
            guard case .act(let request) = result else { return XCTFail(condition) }
            XCTAssertNil(request.args["element_token"], condition)
            XCTAssertNotNil(request.args["x"], condition)
            XCTAssertEqual(request.args["capture_id"], .string("capture-synthetic"), condition)
        }
    }

    func testBindingRejectsSwappedAssetAndImageWithClonedFrameNonce() throws {
        var observation = try visualObservation()
        let original = try XCTUnwrap(observation.screenshot?.frame)
        let binding = VisualBinding(task: observation.task, frame: original)
        let asset = try JevImageAsset(data: image(width: 280, height: 280, marker: 7), format: .png)
        let clone = VisualFrame(asset: asset, captureID: original.captureID,
            window: original.window, session: original.session, bounds: original.bounds,
            driverSize: original.driverSize, contentRect: original.contentRect,
            generation: original.generation, imageHash: original.imageHash, origin: original.origin)
        observation.screenshot = CapturedImage(captureID: clone.captureID, data: asset.data, frame: clone)
        XCTAssertFalse(binding.matches(observation), "A copied nonce must not authorize replacement image bytes")
    }

    private func visualDecision(_ model: VisualModel, _ observation: TaskObservation)
        async throws -> DecideResult {
        let choose = JevChooser.makeVisual(model: "jev-1.14.0") { state, questions, assets in
            try await model.infer(state, questions, assets)
        }
        return try await choose(observation)
    }

    func testOpaqueWindowProducesCaptureBoundImagePointNotDesktopPoint() async throws {
        let model = VisualModel(.click)
        let decision = try await visualDecision(model, visualObservation())
        guard case .act(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(request.tool, "click")
        XCTAssertEqual(request.args["capture_id"], .string("capture-synthetic"))
        XCTAssertEqual(request.args["x"]?.numberValue ?? -1, 84, accuracy: 0.001)
        XCTAssertEqual(request.args["y"]?.numberValue ?? -1, 84, accuracy: 0.001)
        XCTAssertNotNil(request.visualTarget)
        let calls = await model.states
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotNil(calls.last?["proposed"])
        let assets = await model.assets
        XCTAssertEqual(assets.first?.count, 1)
    }

    func testAbsentBoundTargetRejectsEvenValidBox() async throws {
        let model = VisualModel(.absent)
        let decision = try await visualDecision(model, visualObservation())
        guard case .blocked = decision else { return XCTFail("Absent target could actuate: \(decision)") }
        let calls = await model.states
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotNil(calls.last?["proposed"])
    }

    func testPresenceAndLocationCannotGrantPermission() async throws {
        let decision = try await visualDecision(VisualModel(.unauthorized), visualObservation())
        guard case .blocked = decision else { return XCTFail("Presence authorized input: \(decision)") }
    }

    func testUnidentifiableTargetCannotBecomeHarmlessClick() async throws {
        let decision = try await visualDecision(VisualModel(.unknown), visualObservation())
        guard case .blocked = decision else { return XCTFail("Unknown target actuated: \(decision)") }
    }

    func testVisualDenyRuleCannotDisappearWithMissingAXLabels() async throws {
        var observation = try visualObservation()
        observation.task.deny = ["publish"]
        let decision = try await visualDecision(VisualModel(.denied), observation)
        guard case .blocked = decision else { return XCTFail("Visual deny rule bypassed: \(decision)") }
    }

    func testVisualTypingChoosesLaterLiteralAndPreservesEveryByte() async throws {
        var observation = try visualObservation()
        observation.task.values = ["a": "first", "b": "second", "z": "  exact\ntext  "]
        let model = VisualModel(.typing)
        let decision = try await visualDecision(model, observation)
        guard case .act(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(request.tool, "type_text")
        XCTAssertEqual(request.args["text"], .string("  exact\ntext  "))
        let calls = await model.states
        XCTAssertEqual(calls.first?["caller_literals"]?.object?.count, 3)
    }

    func testForeignFrameCannotReachImageInference() async throws {
        var observation = try visualObservation()
        observation.task.window = Jarvis.WindowRef(pid: 8, windowID: 43)
        let model = VisualModel(.click)
        let decision = try await visualDecision(model, observation)
        guard case .blocked = decision else { return XCTFail("\(decision)") }
        let calls = await model.states
        XCTAssertTrue(calls.isEmpty)
    }

    func testMissingTextCannotSolicitAnAnswerBeforeTargetAuthorization() async throws {
        let model = VisualModel(.unauthorizedMissingText)
        let decision = try await visualDecision(model, visualObservation())
        guard case .blocked = decision else {
            return XCTFail("Unverified target solicited text: \(decision)")
        }
        let calls = await model.states
        XCTAssertEqual(calls.count, 2)
    }

    func testLegitimateTextHoleChecksActualFieldBeforeAsking() async throws {
        let model = VisualModel(.missingText)
        let decision = try await visualDecision(model, visualObservation())
        guard case .askUser = decision else { return XCTFail("\(decision)") }
        let calls = await model.states
        XCTAssertEqual(calls.count, 2)
    }

    func testVisualPurchaseCannotLoseTheCanonicalProtectedActionMarker() async throws {
        let decision = try await visualDecision(VisualModel(.purchase), visualObservation())
        guard case .act(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: request.elementText ?? ""), "purchase now")
    }

    func testEditableVoteCannotOverrideContradictoryControlIdentity() async throws {
        var observation = try visualObservation()
        observation.task.values = ["a": "first", "b": "second", "z": "exact text"]
        let decision = try await visualDecision(VisualModel(.typingOnButton), observation)
        guard case .blocked = decision else {
            return XCTFail("Contradictory target identity authorized typing: \(decision)")
        }
    }

    func testRecoveredGroundedAXDoesNotKeepRequestingImages() async throws {
        let decider = JevDecider(choose: { _, _ in
            .init(id: "stuck", confidence: 1, doneVote: false)
        }, visualChoose: { _ in .act(.init(effect: .reobserve, tool: "", summary: "observe")) })
        _ = try await decider.nextStep(decisionObservation(elements: [searchElement()]))
        _ = try await decider.nextStep(visualObservation())
        var recovered = decisionObservation(elements: [searchElement()])
        recovered.stepIndex = 2
        let needs = await decider.needsScreenshot(for: recovered)
        XCTAssertFalse(needs)
    }

    private final class VisualInputSource: CaptureSource, @unchecked Sendable {
        let observation: TaskObservation
        var inputs = 0
        var consents = 0
        init(_ observation: TaskObservation) { self.observation = observation }
        func frontmostWindow() async throws -> Jarvis.WindowRef {
            try XCTUnwrap(observation.task.window)
        }
        func axTree(of window: Jarvis.WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            try XCTUnwrap(observation.axSnapshot)
        }
        func observation(of window: Jarvis.WindowRef, depth: AXDepth,
                         includeScreenshot: Bool) async throws -> CapturedObservation {
            CapturedObservation(snapshot: observation.axSnapshot, image: observation.screenshot)
        }
        func screenshot(of window: Jarvis.WindowRef?, region: CGRect?) async throws -> CapturedImage {
            try XCTUnwrap(observation.screenshot)
        }
        func domSnapshot(of window: Jarvis.WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }
        func settled(within timeout: Duration) async -> Bool { true }
    }

    private struct RequestBrain: Decider {
        let wantsScreenshot = true
        let request: ActuationRequest
        func nextStep(_ observation: TaskObservation) async throws -> DecideResult { .act(request) }
    }

    private final class VisualGoalSource: CaptureSource, @unchecked Sendable {
        let frames: [VisualFrame]
        var captures = 0
        var inputs = 0
        init(_ frames: [VisualFrame]) { self.frames = frames }
        func frontmostWindow() async throws -> Jarvis.WindowRef { frames[0].window }
        func axTree(of window: Jarvis.WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            AXSnapshot(windowTitle: "Synthetic", snapshotID: "opaque-\(captures)",
                       elements: [], treeMarkdown: "", goalContextComplete: false)
        }
        func observation(of window: Jarvis.WindowRef, depth: AXDepth,
                         includeScreenshot: Bool) async throws -> CapturedObservation {
            let frame = frames[min(captures, frames.count - 1)]
            captures += 1
            return CapturedObservation(snapshot: try await axTree(of: window, depth: depth),
                image: CapturedImage(captureID: frame.captureID, data: frame.asset.data, frame: frame))
        }
        func screenshot(of window: Jarvis.WindowRef?, region: CGRect?) async throws -> CapturedImage {
            XCTFail("combined observation was split")
            return CapturedImage()
        }
        func domSnapshot(of window: Jarvis.WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }
        func settled(within timeout: Duration) async -> Bool { true }
    }

    private func visualGoalRun(_ scenario: VisualModel.Scenario, replay: Bool = false,
                               expected: [String] = [], daemonRestart: Bool = false,
                               sessionRestart: Bool = false) async throws
        -> (TaskLoopResult, VisualGoalSource, VisualModel) {
        let progressRun = [.longProgress, .cosmeticProgressOnly, .staticDespiteProgressVote].contains(scenario)
        let frames: [VisualFrame] = try (0..<(progressRun ? 20 : 6)).map { index in
            let socket = daemonRestart && index > 0 ? "/fixture/b.sock" : "/fixture/a.sock"
            let epoch = sessionRestart ? UUID(uuidString: index == 0
                ? "00000000-0000-0000-0000-000000000001"
                : "00000000-0000-0000-0000-000000000002") : nil
            let origin = CuaResultOrigin(session: "test-session", daemonSocket: socket, sessionEpoch: epoch)
            let marker: UInt8 = [.longProgress, .cosmeticProgressOnly].contains(scenario)
                ? UInt8(index + 1)
                : (index > 0 && [.driftingSubject, .actionThenForeignGoal,
                                 .switchBeforeNextInput, .subjectThenAction,
                                 .changedSubject].contains(scenario) ? UInt8(index) : 0)
            let raw = try self.result(changes: [
                "capture_id": .string("capture-\(index)"),
            ], origin: origin, marker: marker)
            return try VisualFrame.decode(raw, window: window, session: "test-session")
        }
        let source = VisualGoalSource(replay ? Array(repeating: frames[0], count: 6) : frames)
        let subjects = Dictionary(uniqueKeysWithValues: frames.enumerated().map {
            ("frame-\($0.element.generation.uuidString)",
             $0.offset > 0 && [.driftingSubject, .actionThenForeignGoal, .switchBeforeNextInput].contains(scenario)
                ? "different-subject" : "original-subject")
        })
        let model = VisualModel(scenario, subjects: subjects)
        let infer: JevChooser.VisualInfer = { state, questions, assets in
            try await model.infer(state, questions, assets)
        }
        let choose = JevChooser.makeVisual(model: "jev-1.14.0", infer: infer)
        let verify = JevChooser.makeVisualVerifier(model: "jev-1.14.0", infer: infer)
        var config = TaskLoop.Config()
        config.maxRounds = progressRun ? 20 : (scenario == .switchBeforeNextInput ? 5 : 4)
        let loop = TaskLoop(source: source, decider: JevDecider(
            choose: { _, _ in XCTFail("opaque goal used AX chooser"); return nil },
            visualChoose: choose), actuate: { _ in
                source.inputs += 1
                return .init(effect: "unverifiable", verified: false)
            }, consent: { _, _ in
                if !progressRun && ![.actionThenForeignGoal, .switchBeforeNextInput].contains(scenario) {
                    XCTFail("goal verification requested mutation consent")
                }
                return .allow
            },
            verifyVisual: verify, config: config)
        let result = await loop.run(TaskBrief(
            goal: "Open Search", window: window, successContains: expected))
        return (result, source, model)
    }

    func testVisualGoalNeedsFreshIndependentProofBeforeDone() async throws {
        let (result, source, model) = try await visualGoalRun(.goal)
        guard case .done = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(source.captures, 2)
        XCTAssertEqual(source.inputs, 0)
        XCTAssertTrue(result.history.contains { $0.echo == .verify && $0.settleVerified })
        let assets = await model.assets
        XCTAssertEqual(assets.map(\.count), [1, 2])
    }

    func testVisualGoalCannotCompleteFromForgeryOfferedButtonOrChangedSubject() async throws {
        for scenario: VisualModel.Scenario in [.forgedGoal, .offeredGoal, .changedSubject] {
            let (result, source, _) = try await visualGoalRun(scenario)
            if case .done = result.outcome { XCTFail("Unverified visual goal completed: \(scenario)") }
            XCTAssertEqual(source.inputs, 0)
            XCTAssertGreaterThanOrEqual(source.captures, 2)
        }
    }

    func testVisualGoalCannotReuseOriginCaptureAsFreshVerification() async throws {
        let (result, source, _) = try await visualGoalRun(.goal, replay: true)
        if case .done = result.outcome { XCTFail("Replayed origin authorized completion") }
        XCTAssertEqual(source.inputs, 0)
    }

    func testVisualGoalCannotProveHiddenOrByteExactOutcomesFromPixels() async throws {
        for scenario: VisualModel.Scenario in [.hiddenGoal, .exactGoal] {
            let (result, source, _) = try await visualGoalRun(scenario)
            if case .done = result.outcome { XCTFail("Pixels proved hidden/byte-exact outcome") }
            XCTAssertEqual(source.inputs, 0)
        }
    }

    func testVisualGoalCannotIgnoreExplicitMissingNativePostconditions() async throws {
        let (result, source, _) = try await visualGoalRun(.goal, expected: ["EXACT_EXPECTED_STATE"])
        if case .done = result.outcome { XCTFail("Image claim bypassed declared native postcondition") }
        XCTAssertEqual(source.inputs, 0)
    }

    func testFailedSubjectProofCannotReanchorTaskToDifferentSubject() async throws {
        let (result, source, _) = try await visualGoalRun(.driftingSubject)
        if case .done = result.outcome {
            XCTFail("A failed subject check silently rebound the task to the new subject")
        }
        XCTAssertEqual(source.inputs, 0)
    }

    func testSubjectMismatchStopsBeforeFurtherDecisionsOrInput() async throws {
        let (result, source, model) = try await visualGoalRun(.subjectThenAction)
        XCTAssertEqual(source.inputs, 0)
        let primaryCalls = await model.primaryCalls
        XCTAssertEqual(primaryCalls, 1)
        guard case .blocked(.safety) = result.outcome else { return XCTFail("\(result.outcome)") }
    }

    func testGoalProofRetainsOriginalSubjectAcrossEarlierActions() async throws {
        let (result, source, _) = try await visualGoalRun(.actionThenForeignGoal)
        if case .done = result.outcome { XCTFail("Outcome was verified only against the replacement subject") }
        XCTAssertEqual(source.inputs, 1)
    }

    func testNextVisualInputCannotMoveToAnotherSubjectInSameWindow() async throws {
        let (result, source, _) = try await visualGoalRun(.switchBeforeNextInput)
        XCTAssertEqual(source.inputs, 1, "Only the first input in the original subject is authorized")
        guard case .blocked(.safety) = result.outcome else { return XCTFail("\(result.outcome)") }
    }

    func testDaemonRestartCannotQualifyAsSameScopeFreshVisualGoal() async throws {
        let (result, source, model) = try await visualGoalRun(.goal, daemonRestart: true)
        XCTAssertEqual(source.inputs, 0)
        guard case .blocked(.safety(let reason)) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(reason, "The visual capture session or target window changed.")
        let requests = await model.assets
        XCTAssertEqual(requests.count, 1, "A new daemon's pixels must not reach the old task's model")
    }

    func testSamePublicSessionWithNewEpochCannotQualifyFreshGoal() async throws {
        let (result, source, model) = try await visualGoalRun(.goal, sessionRestart: true)
        XCTAssertEqual(source.inputs, 0)
        guard case .blocked(.safety(let reason)) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(reason, "The visual capture session or target window changed.")
        let requests = await model.assets
        XCTAssertEqual(requests.count, 1)
    }

    func testTenStepOpaqueWorkflowContinuesOnlyWithSemanticVisualProgress() async throws {
        let (result, source, _) = try await visualGoalRun(.longProgress)
        guard case .done = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(source.inputs, 10)
        XCTAssertEqual(source.captures, 12)
    }

    func testChangedPixelsAndImpossibleVotesCannotDefeatIdleGuard() async throws {
        for scenario: VisualModel.Scenario in [.cosmeticProgressOnly, .staticDespiteProgressVote] {
            let (result, source, _) = try await visualGoalRun(scenario)
            XCTAssertEqual(result.outcome, .escalated(.staleScreen))
            XCTAssertEqual(source.inputs, 8)
        }
    }

    func testDriveLoopProductionSeamUsesScopedCaptureAndFreshVerifier() async throws {
        let raws = try (0..<2).map { index in
            try self.result(changes: ["capture_id": .string("root-capture-\(index)")],
                origin: .init(session: "test-session", daemonSocket: "/fixture/owner.sock"))
        }
        let frames = try raws.map { try VisualFrame.decode($0, window: window, session: "test-session") }
        let source = VisualGoalSource(frames)
        let model = VisualModel(.goal)
        let infer: JevChooser.VisualInfer = { try await model.infer($0, $1, $2) }
        let loop = DriveLoop(call: { tool, args in
            XCTAssertTrue(CuaConnection.isReadOnly(tool, arguments: args), "Captured input reached the legacy retry path")
            return raws[0].structured
        }, choose: { _, _ in XCTFail("Opaque frame used AX chooser"); return nil },
            ask: nil, granted: { true },
            scopedCall: { tool, args, origin in
                XCTAssertEqual(tool, "get_window_state")
                XCTAssertEqual(args["include_screenshot"], .bool(true))
                XCTAssertNil(origin)
                let raw = raws[min(source.captures, raws.count - 1)]
                source.captures += 1
                return raw
            }, visualChoose: JevChooser.makeVisual(model: "jev-1.14.0", infer: infer),
            verifyVisual: JevChooser.makeVisualVerifier(model: "jev-1.14.0", infer: infer),
            resolver: AppResolver(listApps: { [] }), config: .init(maxRounds: 4),
            windowControlButtons: { _ in [] }, windowControlButtonsInWindow: { _, _ in [] },
            resurrector: SessionResurrector(),
            nativeReadOnly: { _, _ in nil })
        let result = await loop.run(DriveTask(
            goal: "Perform the requested workflow", application: "Synthetic", pid: 7, windowID: 42),
            session: "test-session")
        guard case .alreadySatisfied = result.status else { return XCTFail("\(result.status)") }
        XCTAssertEqual(source.captures, 2)
    }

    func testPreviewUsesDemandDrivenImageButNeverVerifiesOrActs() async throws {
        let raw = try result(origin: .init(session: "test-session", daemonSocket: "/fixture/owner.sock"))
        let frame = try VisualFrame.decode(raw, window: window, session: "test-session")
        let source = VisualGoalSource([frame])
        let model = VisualModel(.goal)
        let infer: JevChooser.VisualInfer = { try await model.infer($0, $1, $2) }
        let loop = DriveLoop(call: { tool, args in
            XCTAssertTrue(CuaConnection.isReadOnly(tool, arguments: args))
            if tool == "list_windows" {
                return .object(["windows": .array([.object([
                    "pid": .number(7), "window_id": .number(42),
                ])])])
            }
            return raw.structured
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
            scopedCall: { tool, _, origin in
                XCTAssertEqual(tool, "get_window_state")
                XCTAssertNil(origin)
                source.captures += 1
                return raw
            }, visualChoose: JevChooser.makeVisual(model: "jev-1.14.0", infer: infer),
            verifyVisual: { _, _ in XCTFail("Preview ran a completion verifier"); return nil },
            resolver: AppResolver(listApps: {
                [.init(name: "Synthetic", bundle: "test.synthetic", pid: 7)]
            }), windowControlButtonsInWindow: { _, _ in [] },
            resurrector: SessionResurrector(), nativeReadOnly: { _, _ in nil })
        let text = try await loop.preview(DriveTask(
            goal: "Perform the requested workflow", application: "Synthetic", pid: 7, windowID: 42),
            session: "test-session")
        XCTAssertEqual(text, "The goal may be complete; drive_until must verify it.")
        XCTAssertEqual(source.captures, 1)
    }

    func testLoopRefusesForgedVisualRequestsBeforeConsentOrInput() async throws {
        for mutation in ["capture", "missing_capture", "point", "tool", "goal", "bytes", "generation"] {
            var observation = try visualObservation()
            guard case .act(var request) = try await visualDecision(VisualModel(.click), observation)
            else { return XCTFail("positive fixture did not produce input") }
            switch mutation {
            case "capture": request.args["capture_id"] = .string("foreign-capture")
            case "missing_capture": request.args["capture_id"] = nil
            case "point": request.args["x"] = .number(1)
            case "tool": request.tool = "type_text"
            case "goal": observation.task.goal = "Change another setting"
            case "bytes": observation.screenshot?.data = Data()
            case "generation":
                let fresh = try VisualFrame.decode(result(), window: window, session: "test-session")
                observation.screenshot = CapturedImage(
                    captureID: fresh.captureID, data: fresh.asset.data, frame: fresh)
            default: XCTFail("unknown mutation")
            }
            let source = VisualInputSource(observation)
            var config = TaskLoop.Config()
            config.maxRounds = 1
            let loop = TaskLoop(source: source, decider: RequestBrain(request: request),
                actuate: { _ in
                    source.inputs += 1
                    return .init(effect: "unverifiable", verified: false)
                }, consent: { _, _ in source.consents += 1; return .allow }, config: config)
            let outcome = await loop.run(observation.task)
            guard case .blocked(.safety) = outcome.outcome else {
                XCTFail("\(mutation) did not refuse with safety: \(outcome.outcome)")
                continue
            }
            XCTAssertEqual(outcome.outcome, .blocked(.safety(
                "The visual input does not match the current task, capture, or authorized arguments.")))
            XCTAssertEqual(source.inputs, 0, mutation)
            XCTAssertEqual(source.consents, 0, mutation)
        }
    }
}

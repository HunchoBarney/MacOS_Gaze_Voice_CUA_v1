import ApplicationServices
import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

private actor BlockedSemanticTestWire: RealtimeVoiceWire {
    func send(_ text: String) async throws { throw CancellationError() }
    func receive() async throws -> String { throw CancellationError() }
    func close() async {}
}

/// Protocol/ownership fixtures only. No live service, semantic calibration,
/// microphone, synthesized audio or application effects are claimed here.
@MainActor
final class VoiceSemanticTests: XCTestCase {
    func testR8DirectConversationScrollDoesNotCallSemanticInterpreter() async throws {
        var scope = context()
        scope.windowID = 41
        for (text, direction, small) in [
            ("scroll down", "down", false),
            ("Could you please scroll down a little?", "down", true),
            ("scroll up a bit", "up", true),
            ("scroll the page up", "up", false),
        ] {
            let policy = VoiceAdmissionPolicy.propose(text, context: scope, speech: true)
            let decision = try await ConversationContext().resolve(text, context: scope, policy: policy) { _, _, _ in
                XCTFail("A grounded complete routine control should not require Jev")
                return .init(kind: .clarify)
            }
            XCTAssertTrue(decision.local)
            XCTAssertEqual(decision.kind, .scroll)
            XCTAssertEqual(decision.direction, direction)
            XCTAssertEqual(decision.small, small)
            XCTAssertEqual(decision.windowScroll?.goal, text)
            XCTAssertEqual(decision.scope, .window(app: "fixture.editor", id: 41))
        }
    }

    func testR8UnknownAndConstrainedWordingKeepsItsWholeSemanticRequest() async throws {
        var scope = context()
        scope.windowID = 41
        let memory = verifiedScrollMemory()
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .confirm)
        for text in [
            "Nudge this down", "Don't scroll down", "scroll down, no actually don't",
            "\"scroll down\"", "He said scroll down", "If I ask you to scroll down",
            "scroll down in the sidebar", "scroll down until the heading appears",
            "scroll down and open Chrome", "scroll down 1 time", "scroll down 20 pixels",
            "keep scrolling until the heading appears", "a little more and then close it",
            "scroll down in Google Chrome",
        ] {
            var heard: [String] = []
            let policy = VoiceAdmissionPolicy.propose(text, context: scope, speech: true)
            let decision = try await memory.resolve(text, context: scope, policy: policy) { original, _, _ in
                heard.append(original)
                return .init(kind: .clarify)
            }
            XCTAssertFalse(decision.local, text)
            XCTAssertNil(decision.windowScroll, text)
            XCTAssertEqual(heard, [text], text)
        }
        scope.capturedAsks = [ask]; scope.currentAsks = [ask]
        let text = "scroll down"
        let decision = try await memory.resolve(text, context: scope,
            policy: VoiceAdmissionPolicy.propose(text, context: scope, speech: true)) { _, _, _ in
            .init(kind: .clarify)
        }
        XCTAssertFalse(decision.local)
    }

    func testR8LocalFollowupRetainsVerifiedSubjectAndDistinguishesDuration() async throws {
        var scope = context()
        scope.windowID = 41
        var memory = verifiedScrollMemory()
        memory.discardFragment()
        for (text, kind) in [("a little more", ConversationDecision.Kind.scroll),
                             ("okay, keep scrolling", .continueScroll),
                             ("keep going", .continueScroll)] {
            let policy = VoiceAdmissionPolicy.propose(text, context: scope, speech: true)
            let decision = try await memory.resolve(text, context: scope, policy: policy) { _, _, _ in
                XCTFail("This follow-up has an exact verified referent")
                return .init(kind: .clarify)
            }
            XCTAssertTrue(decision.local)
            XCTAssertEqual(decision.kind, kind)
            XCTAssertEqual(decision.direction, "down")
            XCTAssertTrue(decision.small)
            if kind == .scroll {
                XCTAssertEqual(decision.windowScroll?.continuation?.region, memory.scroll?.viewport.region)
                XCTAssertEqual(decision.windowScroll?.lines, 1)
            }
            scope.windowID = 42
            let changed = try await memory.resolve(text, context: scope,
                policy: VoiceAdmissionPolicy.propose(text, context: scope, speech: true)) { _, _, _ in
                .init(kind: .clarify)
            }
            XCTAssertFalse(changed.local)
            scope.windowID = 41
            let absent = try await ConversationContext().resolve(text, context: scope, policy: policy) { _, _, _ in
                .init(kind: .clarify)
            }
            XCTAssertFalse(absent.local)
        }
    }

    func testR8LocalAppFocusNeedsAnObservedCurrentIdentity() async throws {
        var scope = context()
        scope.windowID = 41
        let text = "open Google Chrome"
        let decision = try await ConversationContext().resolve(text, context: scope,
            policy: VoiceAdmissionPolicy.propose(text, context: scope, speech: true)) { _, _, _ in
            XCTFail("A uniquely observed local app does not require a semantic decision")
            return .init(kind: .clarify)
        }
        XCTAssertTrue(decision.local)
        XCTAssertEqual(decision.kind, .task)
        XCTAssertEqual(decision.scope?.appID, "fixture.chrome")
        scope.entities = []
        XCTAssertFalse(decision.scope?.matches(scope) ?? true)
        let missing = try await ConversationContext().resolve(text, context: scope,
            policy: VoiceAdmissionPolicy.propose(text, context: scope, speech: true)) { _, _, _ in
            .init(kind: .clarify)
        }
        XCTAssertFalse(missing.local)
    }

    func testR8RejectedOrUnverifiedTurnCannotResumeAnOlderScroll() async throws {
        var scope = context()
        scope.windowID = 41
        for outcome in ["clarify", "semantic failure", "unrelated task", "unverified scroll"] {
            var memory = verifiedScrollMemory()
            if outcome == "clarify" || outcome == "semantic failure" {
                let text = "make it nicer"
                do {
                    let decision = try await memory.resolve(text, context: scope,
                        policy: VoiceAdmissionPolicy.propose(text, context: scope, speech: true)) { _, _, _ in
                        if outcome == "semantic failure" { throw VoiceSemanticRouter.Failure.unavailable }
                        return .init(kind: .clarify)
                    }
                    XCTAssertEqual(decision.kind, .clarify)
                } catch VoiceSemanticRouter.Failure.unavailable {
                    XCTAssertEqual(outcome, "semantic failure")
                }
                memory.discardRequest()
            } else if outcome == "unrelated task" {
                memory.remember("Open Chrome", scope: .application(scope.entities[0]))
                memory.recordVerification(false)
            } else {
                memory.recordVerification(false)
            }
            for text in ["keep going", "keep scrolling", "a little more"] {
                var semanticTexts: [String] = []
                let decision = try await memory.resolve(text, context: scope,
                    policy: VoiceAdmissionPolicy.propose(text, context: scope, speech: true)) { original, _, _ in
                    semanticTexts.append(original)
                    return .init(kind: .clarify)
                }
                XCTAssertFalse(decision.local, "\(outcome): \(text)")
                XCTAssertEqual(decision.kind, .clarify, "\(outcome): \(text)")
                XCTAssertEqual(semanticTexts, [text], "\(outcome): \(text)")
                XCTAssertNil(decision.windowScroll)
            }
        }
    }

    func testConversationNegationCannotBecomeALocalStopWhenSplitAcrossFinals() {
        for prefix in ["Don't.", "Do not", "Please don't", "Never"] {
            XCTAssertTrue(ConversationContext.isNegativeFragment(prefix))
            XCTAssertNil(ConversationContext.localControl("stop", after: prefix))
        }
        XCTAssertEqual(ConversationContext.localControl("stop", after: "scroll down"), .stop)
        XCTAssertEqual(ConversationContext.localControl("stop", after: "stop"), .stop)
    }

    private func conversationResponse(kind: String = "scroll", addressed: Double = 0.99,
                                      complete: Double = 0.99, support: Double = 0.99,
                                      bounded: Double = 0.99, extent: String = "single",
                                      reference: Double = 0.01, continuation: Double = 0.99) throws -> SystemOneResponse {
        func choice(_ value: String) -> [String: Any] {
            ["type": "choice", "choice": value, "confidence": 1, "probabilities": [value: 1.0]]
        }
        func noul(_ value: Double) -> [String: Any] { ["type": "noul", "noul": value] }
        return try JSONDecoder().decode(SystemOneResponse.self, from: JSONSerialization.data(withJSONObject: [
            "model": "protocol-fixture-not-calibrated",
            "answers": ["kind": choice(kind), "addressed": noul(addressed), "complete": noul(complete),
                "scope": choice("window"), "scope_requested_window": noul(0.99),
                "direction": choice("down"), "scroll_supported_down": noul(support),
                "amount": choice("small"), "small_requested": noul(0.99),
                "bounded_window_scroll": noul(bounded),
                "scroll_extent": choice(extent), "verified_scroll_reference": noul(reference),
                "continue_supported": noul(continuation)],
            "usage": ["input_tokens": 1, "output_tokens": 1],
        ]))
    }

    private func verifiedScrollMemory() -> ConversationContext {
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(424242))
        let window = WindowRef(pid: 424242, windowID: 41)
        let viewport = NativeWindowObservation.ScrollViewport(
            window: window, root: identity, region: identity, meter: identity,
            content: identity, document: NativeWindowObservation.documentSubject(
                window: window, identifier: "file:///owned.txt"),
            title: Data("Owned".utf8), frame: CGRect(x: 0, y: 30, width: 400, height: 270),
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentSize: CGSize(width: 400, height: 2000), contentDigest: Data("body".utf8),
            point: CGPoint(x: 200, y: 165), metric: .verticalBar, position: 0.2,
            minimum: 0, maximum: 1, capturedAt: 1)
        var memory = ConversationContext()
        let scope = ConversationScope.window(app: "fixture.editor", id: 41)
        memory.remember("Scroll down a little.", scope: scope)
        memory.recordVerification(true)
        memory.scroll = .init(scope: scope, direction: "down", small: true, viewport: viewport)
        return memory
    }

    func testR7BoundedFollowupCannotBecomeContinuousFromKindAlone() throws {
        var scope = context()
        scope.windowID = 41
        let memory = verifiedScrollMemory()
        let request = try VoiceSemanticRouter.conversationRequest("A little more.", context: scope, memory: memory)
        let decision = try VoiceSemanticRouter.decodeConversation(
            conversationResponse(kind: "continue_scroll", extent: "single", reference: 0.99),
            request: request, context: scope, memory: memory)
        XCTAssertEqual(decision.kind, .scroll)
        XCTAssertNotNil(decision.windowScroll)
        XCTAssertEqual(decision.windowScroll?.goal, "A little more.")
    }

    func testR7UntilConditionCannotEnterUnboundedContinuation() throws {
        var scope = context()
        scope.windowID = 41
        let memory = verifiedScrollMemory()
        let request = try VoiceSemanticRouter.conversationRequest(
            "Keep scrolling until Cedar is visible.", context: scope, memory: memory)
        let decision = try VoiceSemanticRouter.decodeConversation(
            conversationResponse(kind: "continue_scroll", bounded: 0.01, extent: "clarify", reference: 0.99),
            request: request, context: scope, memory: memory)
        XCTAssertEqual(decision.kind, .task)
        XCTAssertNil(decision.windowScroll)
    }

    func testR7ReferenceRequiresCurrentNativeSubjectAndIndependentSupport() throws {
        var scope = context()
        scope.windowID = 41
        let memory = verifiedScrollMemory()
        for reference in [0.5, 0.89, 0.99] {
            let request = try VoiceSemanticRouter.conversationRequest("A little more.", context: scope, memory: memory)
            let result = try VoiceSemanticRouter.decodeConversation(
                conversationResponse(reference: reference), request: request, context: scope, memory: memory)
            if reference == 0.99 {
                XCTAssertEqual(result.kind, .scroll)
                XCTAssertEqual(result.windowScroll?.continuation?.window, memory.scroll?.viewport.window)
                XCTAssertEqual(result.windowScroll?.continuation?.region, memory.scroll?.viewport.region)
                XCTAssertEqual(result.windowScroll?.goal, "A little more.")
            } else {
                XCTAssertEqual(result.kind, .clarify)
                XCTAssertNil(result.windowScroll)
            }
        }
        scope.windowID = 42
        let changed = try VoiceSemanticRouter.conversationRequest("A little more.", context: scope, memory: memory)
        XCTAssertEqual(try VoiceSemanticRouter.decodeConversation(conversationResponse(reference: 0.99),
            request: changed, context: scope, memory: memory).kind, .clarify)
        let absent = try VoiceSemanticRouter.conversationRequest("A little more.", context: scope, memory: .init())
        XCTAssertEqual(try VoiceSemanticRouter.decodeConversation(conversationResponse(reference: 0.99),
            request: absent, context: scope, memory: .init()).kind, .clarify)
    }

    func testR7ContinuousExtentStillRequiresWholeInstructionSupport() throws {
        var scope = context()
        scope.windowID = 41
        let memory = verifiedScrollMemory()
        let request = try VoiceSemanticRouter.conversationRequest("Keep scrolling.", context: scope, memory: memory)
        let valid = try VoiceSemanticRouter.decodeConversation(
            conversationResponse(kind: "continue_scroll", extent: "ongoing", reference: 0.99),
            request: request, context: scope, memory: memory)
        XCTAssertEqual(valid.kind, .continueScroll)
        XCTAssertNil(valid.windowScroll)
        let weak = try VoiceSemanticRouter.decodeConversation(
            conversationResponse(kind: "continue_scroll", extent: "ongoing", reference: 0.99, continuation: 0.89),
            request: request, context: scope, memory: memory)
        XCTAssertNotEqual(weak.kind, .continueScroll)
        XCTAssertNil(weak.windowScroll)
    }

    func testR7ScrollSelectionCannotDiscardAnUnprovenWholeGoal() throws {
        var scope = context()
        scope.windowID = 41
        for text in ["Move down a little until Cedar is visible.",
                     "Scroll the sidebar down.", "Scroll down and click Save.",
                     "Scroll down exactly three pages."] {
            let request = try VoiceSemanticRouter.conversationRequest(text,
                context: scope, memory: ConversationContext())
            XCTAssertNotNil(request.questions["bounded_window_scroll"])
            let decision = try VoiceSemanticRouter.decodeConversation(
                conversationResponse(bounded: 0.89), request: request,
                context: scope, memory: ConversationContext())
            XCTAssertEqual(decision.kind, .task, text)
            XCTAssertEqual(decision.scope, .window(app: "fixture.editor", id: 41))
            XCTAssertEqual(request.state["utterance"], .string(text))
        }
    }

    func testConversationSelectionCannotOverrideWeakRequestSupport() throws {
        var scope = context()
        scope.windowID = 41
        let memory = ConversationContext()
        let request = try VoiceSemanticRouter.conversationRequest("scroll down a little", context: scope, memory: memory)
        let weak = try VoiceSemanticRouter.decodeConversation(conversationResponse(support: 0.7),
            request: request, context: scope, memory: memory)
        XCTAssertEqual(weak.kind, .clarify)
        let strong = try VoiceSemanticRouter.decodeConversation(conversationResponse(),
            request: request, context: scope, memory: memory)
        XCTAssertEqual(strong.kind, .scroll)
        XCTAssertEqual(strong.scrollGoal, "scroll down a little")
        XCTAssertEqual(strong.scope, .window(app: "fixture.editor", id: 41))
    }

    func testR7SemanticScrollBindsOriginalTextAndObservedWindow() throws {
        var scope = context()
        scope.windowID = 41
        let text = "A tiny scroll toward the bottom, please."
        let request = try VoiceSemanticRouter.conversationRequest(text, context: scope, memory: .init())
        let decision = try VoiceSemanticRouter.decodeConversation(conversationResponse(),
            request: request, context: scope, memory: .init())
        let native = try XCTUnwrap(decision.windowScroll)
        XCTAssertEqual(native.goal, text)
        XCTAssertEqual(native.direction, "down")
        XCTAssertEqual(native.lines, 1)
        XCTAssertTrue(native.matches(DriveTask(goal: text, application: "fixture.editor", windowID: 41)))
        scope.windowID = 42
        let changed = try VoiceSemanticRouter.decodeConversation(conversationResponse(),
            request: request, context: scope, memory: .init())
        XCTAssertEqual(changed.kind, .clarify)
        XCTAssertNil(changed.windowScroll)
    }

    func testR7MissingOrMalformedBoundedJudgmentCannotAuthorizeNativeScroll() throws {
        var scope = context()
        scope.windowID = 41
        let request = try VoiceSemanticRouter.conversationRequest("Scroll down a little.",
            context: scope, memory: .init())
        for value: Double? in [nil, .nan, 1.1, -0.1] {
            var answers = try conversationResponse().answers
            answers["bounded_window_scroll"] = value.map(Answer.noul)
            let response = SystemOneResponse(model: "protocol-fixture-not-calibrated",
                answers: answers, usage: nil)
            XCTAssertThrowsError(try VoiceSemanticRouter.decodeConversation(response,
                request: request, context: scope, memory: .init()))
        }
    }

    func testConversationDoesNotActOnAmbientOrIncompleteSpeechOrMissingAnchor() throws {
        var scope = context()
        scope.windowID = 41
        let memory = ConversationContext()
        let request = try VoiceSemanticRouter.conversationRequest("keep scrolling", context: scope, memory: memory)
        XCTAssertEqual(try VoiceSemanticRouter.decodeConversation(conversationResponse(addressed: 0.4),
            request: request, context: scope, memory: memory).kind, .ignore)
        XCTAssertEqual(try VoiceSemanticRouter.decodeConversation(conversationResponse(complete: 0.4),
            request: request, context: scope, memory: memory).kind, .incomplete)
        XCTAssertEqual(try VoiceSemanticRouter.decodeConversation(conversationResponse(kind: "continue_scroll", extent: "ongoing"),
            request: request, context: scope, memory: memory).kind, .clarify)
    }

    func testConversationRetainsNegationAndRejectsAFragmentAfterWindowChange() throws {
        var scope = context()
        scope.windowID = 41
        var memory = ConversationContext()
        memory.hold("Don't", scope: .window(scope))
        let combined = try memory.combined("open Chrome", context: scope)
        XCTAssertEqual(combined, "Don't\nopen Chrome")
        XCTAssertEqual(VoiceAdmissionPolicy.propose(combined, context: scope).route, .refuse)
        scope.windowID = 42
        XCTAssertThrowsError(try memory.combined("open Chrome", context: scope))
    }

    private actor Requests {
        var count = 0
        func increment() { count += 1 }
    }
    private func context() -> VoiceAdmissionContext {
        var c = VoiceAdmissionContext()
        c.targetID = "fixture.window"; c.targetAppID = "fixture.editor"
        c.entities = [.init(name: "Google Chrome", id: "fixture.chrome", canOpenLocally: true)]
        c.appRoles = ["https": "fixture.chrome"]
        return c
    }

    private func admission(_ text: String = "I need my web browser over here") async throws -> VoiceAdmission {
        let session = LocalSpeechSession { _ in }
        session.context = context()
        let result = await session.submitTyped(text, now: 1)
        return try XCTUnwrap(result)
    }

    private func response(action: String = "focus_app", target: String = "app_0",
                          targetMass: [String: Double] = ["app_0": 1]) throws -> SystemOneResponse {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "protocol-fixture-not-calibrated",
            "answers": [
                "operation": ["type": "choice", "choice": action == "focus_app" ? target : action,
                              "confidence": 1,
                              "probabilities": action == "focus_app" ? targetMass : [action: 1]] as [String: Any]
            ],
            "usage": ["input_tokens": 1, "output_tokens": 1]
        ])
        return try JSONDecoder().decode(SystemOneResponse.self, from: data)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    func testBatchedRequestContainsOnlyBoundedActionsAndObservedAppData() async throws {
        let c = context(), input = try await admission()
        XCTAssertTrue(VoiceSemanticRouter.eligible(input, context: c))
        let request = try VoiceSemanticRouter.request(input.text, context: c)
        XCTAssertEqual(Set(request.questions.keys), ["operation"])
        XCTAssertEqual(Set(request.state.object?.keys.map { $0 } ?? []),
                       ["input_mode", "utterance", "frontmost_app", "app_roles", "observed_apps"])
        XCTAssertEqual(request.state["input_mode"], .string("explicit_assistant_command"))
        XCTAssertEqual(request.state["app_roles"]?["https"], .string("fixture.chrome"))
        XCTAssertEqual(request.targets["app_0"]?.id, "fixture.chrome")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request.questions)) as? [String: Any])
        let action = try XCTUnwrap(json["operation"] as? [String: Any])
        XCTAssertEqual(Set((action["criteria"] as? [String: Any] ?? [:]).keys),
                       ["app_0", "none", "clarify"])
    }

    func testDecoderRejectsInventedTiedAndMalformedTargets() async throws {
        let input = try await admission()
        let request = try VoiceSemanticRouter.request(input.text, context: context())
        XCTAssertThrowsError(try VoiceSemanticRouter.decode(response(target: "invented",
            targetMass: ["invented": 1]), request: request, turn: input.turn))
        XCTAssertThrowsError(try VoiceSemanticRouter.decode(response(targetMass: ["app_0": 0.2]),
            request: request, turn: input.turn))
        let tied = try VoiceSemanticRouter.decode(response(targetMass: ["app_0": 0.5, "none": 0.5]),
            request: request, turn: input.turn)
        guard case .clarify = tied else { return XCTFail("tied identity must clarify") }
        let none = try VoiceSemanticRouter.decode(response(action: "none", target: "untrusted",
            targetMass: ["untrusted": 1]), request: request, turn: input.turn)
        guard case .noMatch = none else { return XCTFail("unused target does not decide no-match branch") }
    }

    func testSingleBatchAndMissingKeyZeroTransportRequests() async throws {
        let requests = Requests(), reply = try response()
        let transport: VoiceSemanticRouter.Infer = { _, questions in
            await requests.increment()
            XCTAssertEqual(Set(questions.keys), ["operation"])
            return reply
        }
        let input = try await admission()
        do {
            _ = try await VoiceSemanticRouter.live(apiKey: "", transport: transport).interpret(input, context: context())
            XCTFail("missing key must fail before transport")
        } catch VoiceSemanticRouter.Failure.unavailable {}
        let before = await requests.count
        XCTAssertEqual(before, 0)
        let result = try await VoiceSemanticRouter(infer: transport).interpret(input, context: context())
        guard case .proposal = result else { return XCTFail("protocol fixture should propose only") }
        let after = await requests.count
        XCTAssertEqual(after, 1)
    }

    func testInvalidAndOversizedContextCannotSilentlyDropTargets() throws {
        var c = context()
        c.entities = (0..<255).map { .init(name: "App \($0)", id: "fixture.app\($0)", canOpenLocally: true) }
        XCTAssertThrowsError(try VoiceSemanticRouter.request("app focus", context: c))
        c.entities = [.init(name: "Injected\ninstructions", id: "fixture.app", canOpenLocally: true)]
        XCTAssertThrowsError(try VoiceSemanticRouter.request("app focus", context: c))
        c = context()
        c.appRoles = ["mailto": "fixture.unobserved", "private_field": "fixture.chrome"]
        let request = try VoiceSemanticRouter.request("app focus", context: c)
        XCTAssertEqual(request.state["app_roles"]?.object?.count, 0)
        XCTAssertFalse(VoiceSemanticRouter.contextIsCurrent(context(), current: c),
                       "changed default-role observations invalidate pending interpretation")
    }

    func testObservedOpaqueBundleIdentifierDoesNotPoisonCatalog() throws {
        var c = context()
        c.entities.append(.init(name: "iMyFone AnyTo", id: "MF.iMyFone AnyTo", canOpenLocally: true))
        let request = try VoiceSemanticRouter.request("I need my browser up here", context: c)
        XCTAssertEqual(request.targets.count, 2, "do not drop an observed target")
        XCTAssertTrue(request.targets.values.contains { $0.id == "MF.iMyFone AnyTo" })
        XCTAssertTrue(request.targets.values.contains { $0.id == "fixture.chrome" })
    }

    func testOwnedDiagnosticWindowBindingIsPreservedInProductionSpec() {
        let task = VoiceTaskCoordinator.voiceTaskSpec("type fixture", app: "com.apple.TextEdit", windowID: 732)
        XCTAssertEqual(task.application, "com.apple.TextEdit")
        XCTAssertEqual(task.windowID, 732)
        XCTAssertNil(VoiceTaskCoordinator.voiceTaskSpec("type fixture", app: "com.apple.TextEdit").windowID)
    }

    func testKnownRoutesAndAsksNeverUseSemanticEligibility() async throws {
        let base = context()
        for text in ["show Google Chrome", "don't show Google Chrome", "hello", "Google?",
                     "I do not want Chrome opened"] {
            let input = try await admission(text)
            XCTAssertFalse(VoiceSemanticRouter.eligible(input, context: base), text)
        }
        var c = base
        c.currentAsks = [.init(taskID: UUID(), askID: UUID())]
        let input = try await admission()
        XCTAssertFalse(VoiceSemanticRouter.eligible(input, context: c))
    }

    private func lane(_ c: VoiceAdmissionContext) -> RealtimeVoiceLane {
        let client = RealtimeVoiceClient(wireFactory: { _ in
            XCTFail("no real OpenAI connection allowed in these fixtures")
            return BlockedSemanticTestWire()
        })
        let lane = RealtimeVoiceLane(apiKey: { "" }, client: client)
        lane.admissionContextProvider = { c }
        lane.semanticContextProvider = { c }
        return lane
    }

    func testUnresolvedAppFramesAndBareNamesReachBoundedSemanticFocus() async throws {
        for (text, name, target, role) in [
            ("show Google", "Chrome", "fixture.chrome", "https"),
            ("open my browser", "Chrome", "fixture.chrome", "https"),
            ("switch to my email app", "Mail", "fixture.mail", "mailto"),
            ("calc", "Calculator", "fixture.calculator", "")
        ] {
            var c = context()
            c.entities = [.init(name: name, id: target, canOpenLocally: true)]
            c.appRoles = role.isEmpty ? [:] : [role: target]
            let speech = lane(c)
            speech.semanticEnabled = { true }
            var requests = 0, typedFocusCalls = 0
            var messages: [String] = []
            speech.onEvent = { _, event in
                if case .toolSay(let message) = event { messages.append(message) }
            }
            speech.semanticInterpretation = { admission, captured in
                requests += 1
                XCTAssertEqual(admission.route, .clarify, text)
                let request = try VoiceSemanticRouter.request(admission.text, context: captured)
                return try VoiceSemanticRouter.decode(self.response(), request: request, turn: admission.turn)
            }
            speech.semanticConfirmationHandler = { proposal in
                XCTAssertEqual(proposal.target.id, target)
                typedFocusCalls += 1
                return true
            }
            speech.commandHandler = { _, _, _, _, _, _ in XCTFail("no generic handoff"); return "{}" }
            try await speech.submitTyped(text, sessionID: UUID())
            XCTAssertEqual(requests, 1, text)
            XCTAssertEqual(typedFocusCalls, 1, text)
            XCTAssertFalse(messages.contains { $0.contains("Please clarify") }, text)
            speech.cancel()
        }
    }

    func testUnresolvedAppSemanticNoMatchKeepsOriginalClarificationWithoutOpenAI() async throws {
        let speech = lane(context())
        speech.semanticEnabled = { true }
        var requests = 0, messages: [String] = []
        speech.semanticInterpretation = { _, _ in requests += 1; return .noMatch }
        speech.semanticConfirmationHandler = { _ in XCTFail("no-match cannot focus"); return false }
        speech.onEvent = { _, event in
            if case .toolSay(let message) = event { messages.append(message) }
        }
        try await speech.submitTyped("open my browser", sessionID: UUID())
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(messages.filter { $0.contains("Please clarify") }.count, 1)
        speech.cancel()
    }

    func testUnresolvedAppSemanticHandledRepliesNeverAppendGenericClarification() async throws {
        for mode in ["clarify", "unavailable", "failure", "stale"] {
            let c = context(), speech = lane(c)
            speech.semanticEnabled = { true }
            if mode != "unavailable" {
                speech.semanticInterpretation = { _, _ in
                    if mode == "failure" { throw VoiceSemanticRouter.Failure.unavailable }
                    return .clarify
                }
                speech.semanticConfirmationHandler = { _ in XCTFail("no focus expected"); return false }
            }
            if mode == "stale" {
                speech.semanticContextProvider = {
                    var changed = c
                    changed.targetID = "changed.window"
                    return changed
                }
            }
            var messages: [String] = []
            speech.onEvent = { _, event in
                if case .toolSay(let message) = event { messages.append(message) }
            }
            try await speech.submitTyped("open my browser", sessionID: UUID())
            XCTAssertEqual(messages.count, 1, mode)
            XCTAssertFalse(messages.contains { $0.contains("Please clarify") }, mode)
            speech.cancel()
        }
    }

    func testUnresolvedAppOptOutPreservesClarificationAndUnknownNameCannotAct() async throws {
        for enabled in [false, true] {
            let speech = lane(context())
            speech.semanticEnabled = { enabled }
            var requests = 0
            speech.semanticInterpretation = { _, _ in requests += 1; return .clarify }
            speech.semanticConfirmationHandler = { _ in XCTFail("unknown identity cannot focus"); return false }
            speech.commandHandler = { _, _, _, _, _, _ in XCTFail("no generic execution"); return "{}" }
            try await speech.submitTyped("open GateHub", sessionID: UUID())
            XCTAssertEqual(requests, enabled ? 1 : 0)
            speech.cancel()
        }
    }

    func testBareObservedNamesDispatchCanonicalFocusLocally() async throws {
        for (text, name, target) in [
            ("Google", "Google Chrome", "fixture.chrome"), ("Chrome", "Google Chrome", "fixture.chrome"),
            ("TextEdit", "TextEdit", "fixture.editor"), ("Terminal", "Terminal", "fixture.terminal")
        ] {
            var c = context()
            c.entities = [.init(name: name, id: target, canOpenLocally: true)]
            let speech = lane(c)
            speech.semanticEnabled = { true }
            speech.semanticInterpretation = { _, _ in XCTFail("known name stays local"); return .clarify }
            speech.semanticConfirmationHandler = { _ in XCTFail("no approval"); return false }
            var calls = 0
            speech.commandHandler = { command, app, _, transcript, _, _ in
                XCTAssertEqual(command, "show \(name)")
                XCTAssertEqual(app, target)
                XCTAssertEqual(transcript, text)
                calls += 1
                return #"{"status":"done","say":"Done."}"#
            }
            try await speech.submitTyped(text, sessionID: UUID())
            XCTAssertEqual(calls, 1, text)
            speech.cancel()
        }
    }

    func testBareNameLookupDoesNotRewriteQuotedOrAnsweredOrUnknownInput() {
        var c = context()
        for text in ["\"Google\"", "'Google'", "Google?", "what about Google", "Google is mentioned", "Googler"] {
            XCTAssertEqual(VoiceAdmissionPolicy.commandText(text, context: c), text)
        }
        c.capturedAsks = [.init(taskID: UUID(), askID: UUID(), kind: .question)]
        c.currentAsks = c.capturedAsks
        XCTAssertEqual(VoiceAdmissionPolicy.commandText("Google", context: c), "Google")
        c.capturedAsks = []
        XCTAssertEqual(VoiceAdmissionPolicy.commandText("Google", context: c), "Google")
    }

    func testBareAppLookupCannotCaptureGreetingsOrPermissionReplies() {
        var c = context()
        for text in ["hello", "thanks", "yes", "approve", "always allow"] {
            c.entities = [.init(name: text, id: "fixture.named", canOpenLocally: true)]
            XCTAssertEqual(VoiceAdmissionPolicy.commandText(text, context: c), text)
            XCTAssertNotEqual(VoiceAdmissionPolicy.propose(text, context: c).intent, "open")
        }
    }

    func testBareAmbiguousObservedVendorStillRequiresSemanticJudgment() async throws {
        var c = context()
        c.entities.append(.init(name: "Google Drive", id: "fixture.drive", canOpenLocally: true))
        let speech = lane(c)
        speech.semanticEnabled = { true }
        var requests = 0
        speech.semanticInterpretation = { _, _ in requests += 1; return .clarify }
        speech.semanticConfirmationHandler = { _ in XCTFail("ambiguous target cannot execute"); return false }
        speech.commandHandler = { _, _, _, _, _, _ in XCTFail("ambiguous target cannot execute"); return "{}" }
        try await speech.submitTyped("Google", sessionID: UUID())
        XCTAssertEqual(requests, 1)
        speech.cancel()
    }

    func testDisabledAssistDoesNotInvokeInference() async throws {
        let lane = lane(context())
        lane.semanticEnabled = { false }
        var count = 0
        lane.semanticInterpretation = { _, _ in count += 1; return .clarify }
        lane.semanticConfirmationHandler = { _ in XCTFail("no proposal expected"); return false }
        _ = try? await lane.submitTyped("I need my web browser over here", sessionID: UUID())
        XCTAssertEqual(count, 0)
        lane.cancel()
    }

    func testBoundedAuditCannotFallThroughToOpenAI() async throws {
        let lane = lane(context())
        lane.remoteReasoningPermitted = false
        do {
            try await lane.submitTyped("I need help with this workflow", sessionID: UUID())
            XCTFail("diagnostic must refuse unauthorized remote reasoning")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disabled for this bounded diagnostic run"))
        }
        lane.cancel()
    }

    func testTraceDoesNotChangeAdmissionOrDispatchCount() async throws {
        var counts: [Int] = []
        for observing in [false, true] {
            let lane = lane(context()), trace = VoiceCommandTrace(), id = UUID()
            var count = 0
            if observing {
                for _ in 0..<300 { trace.record(.contextBegin, turn: UUID()) }
                lane.onCommandStage = { turn, stage in trace.record(stage, turn: turn) }
            }
            lane.commandHandler = { _, _, _, _, _, _ in count += 1; return #"{"status":"done","say":"Done."}"# }
            try await lane.submitTyped("show Google Chrome", sessionID: id)
            counts.append(count)
            if observing {
                XCTAssertTrue(trace.events.contains { $0.turn == id && $0.stage == .admissionLocal })
                XCTAssertTrue(trace.events.contains { $0.turn == id && $0.stage == .localBegin })
                XCTAssertTrue(trace.events.contains { $0.turn == id && $0.stage == .localEnd })
            }
            lane.cancel()
        }
        XCTAssertEqual(counts, [1, 1])
    }

    func testRefusedAdmissionHasNoHandoff() async throws {
        let lane = lane(context()), trace = VoiceCommandTrace()
        lane.onCommandStage = { turn, stage in trace.record(stage, turn: turn) }
        lane.commandHandler = { _, _, _, _, _, _ in XCTFail("refusal cannot execute"); return "{}" }
        try await lane.submitTyped("don't show Google Chrome", sessionID: UUID())
        XCTAssertTrue(trace.events.contains { $0.stage == .admissionRefuse })
        XCTAssertFalse(trace.events.contains { $0.stage == .localBegin })
        lane.cancel()
    }

    func testShowGoogleStaysLocalWithNoSemanticInferenceOrApproval() async throws {
        let speech = lane(context())
        speech.semanticEnabled = { true }
        speech.semanticInterpretation = { _, _ in XCTFail("exact app request stays local"); return .clarify }
        speech.semanticConfirmationHandler = { _ in XCTFail("no approval for show Google"); return false }
        var dispatched = 0
        speech.commandHandler = { _, target, _, _, _, _ in
            XCTAssertEqual(target, "fixture.chrome")
            dispatched += 1
            return #"{"status":"done","say":"Done."}"#
        }
        try await speech.submitTyped("show Google", sessionID: UUID())
        XCTAssertEqual(dispatched, 1)
        speech.cancel()
    }

    func testALocalRepairWordReachesTheDriveLoopAsSpokenNotAsUndo() async throws {
        var c = context()
        c.windowID = 7
        c.undoOffered = true
        for phrase in ["no", "not that", "wrong one", "that's wrong"] {
            let speech = lane(c)
            speech.semanticEnabled = { false }
            var commands: [String] = []
            speech.commandHandler = { command, _, _, _, _, _ in
                commands.append(command)
                return #"{"status":"done","say":"Put it back."}"#
            }
            try await speech.submitTyped(phrase, sessionID: UUID())
            XCTAssertEqual(commands, [phrase], "a bare \"undo\" would press ⌘Z once the offer has gone")
            speech.cancel()
        }
    }

    private func tracedComposition(failing: Bool = false, capturedWindow: Int? = nil)
        -> (VoiceController, VoiceTaskCoordinator) {
        let config = Config(defaults: UserDefaults(suiteName: "composition-\(UUID())")!,
            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        let resolver = AppResolver.fixture(listApps: {
            [.init(name: "Google Chrome", bundle: "fixture.chrome", pid: 42)]
        })
        let coordinator = VoiceTaskCoordinator(config: config, jevRoute: { ServiceRoute(url: JevClient.systemOneURL, bearer: "SensitiveSentinelValue") },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay(), resolver: resolver, commandDriver: { tool, _ in
                if capturedWindow != nil { throw CancellationError() }
                if tool == "bring_to_front" {
                    if failing { throw NSError(domain: "SensitiveSentinelValue", code: 9) }
                    return .object(["activated": .bool(true),
                        "exact_window_effect": .object(["verified": .bool(true)])])
                }
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "is_on_screen": .bool(true), "title": .string("SensitiveSentinelValue")
                ])])])
            })
        coordinator.gazeContextProvider = { nil }
        let speech = lane(context())
        let controller = VoiceController.inert(config: config, speech: speech, authorize: { false },
            frontmost: { nil }, cuaRuntime: coordinator)
        speech.admissionContextProvider = {
            var c = self.context()
            if let capturedWindow {
                c.windowID = capturedWindow; c.targetAppID = "fixture.chrome"; c.editableTarget = true
            }
            return c
        }
        speech.semanticContextProvider = { self.context() }
        return (controller, coordinator)
    }

    func testNormalLocalControllerPreservesCapturedWindowWithoutAuditBinding() async throws {
        for command in ["type \"P3 owned text\"", "undo", "scroll down", "show Google Chrome"] {
            let (controller, coordinator) = tracedComposition(capturedWindow: 732)
            controller.submitTypedCommand(command)
            await waitFor { coordinator.tasks.count == 1 }
            let work = try XCTUnwrap(coordinator.tasks.first)
            XCTAssertEqual(work.spec.windowID, command == "show Google Chrome" ? nil : 732, command)
            controller.cancelCaptureAttempt()
        }
    }

    func testNormalLocalControllerUsesOneLiteralForGoalAndPayload() async throws {
        for command in ["type hello Jarvis.", "type \" \tCase, punctuation!\t \""] {
            let (controller, coordinator) = tracedComposition(capturedWindow: 732)
            controller.submitTypedCommand(command)
            await waitFor { coordinator.tasks.count == 1 }
            let work = try XCTUnwrap(coordinator.tasks.first)
            let literal = try XCTUnwrap(work.spec.values["text"])
            XCTAssertEqual(work.spec.goal, "type \"\(literal)\"")
            XCTAssertEqual(work.spec.windowID, 732)
            controller.cancelCaptureAttempt()
        }
    }

    func testSpeechLiteralSlotAndExecutionGoalAgreeAfterASRPunctuation() throws {
        var c = context()
        c.windowID = 732; c.editableTarget = true
        for raw in ["Type hello Jarvis.", "Type hello, Jarvis!", "Type \"Case, punctuation!\""] {
            let proposal = VoiceAdmissionPolicy.propose(raw, context: c, speech: true)
            XCTAssertEqual(proposal.route, .local)
            let literal = try XCTUnwrap(proposal.slots["text"])
            let task = VoiceTaskCoordinator.voiceTaskSpec(raw, app: "fixture.chrome",
                values: proposal.slots, windowID: 732)
            XCTAssertEqual(task.goal, "type \"\(literal)\"")
            XCTAssertEqual(task.values["text"], literal)
        }
    }

    func testCapturedWindowGetterRejectsOtherAndCompletedTurns() async throws {
        var c = context()
        c.windowID = 732; c.editableTarget = true
        let speech = lane(c), id = UUID()
        var captured: Int?
        speech.commandHandler = { [weak speech] _, _, _, _, _, turn in
            captured = speech?.capturedLocalWindowID(for: turn)
            XCTAssertNil(speech?.capturedLocalWindowID(for: UUID()))
            return #"{"status":"done","say":"Done."}"#
        }
        try await speech.submitTyped("type fixture", sessionID: id)
        XCTAssertEqual(captured, 732)
        XCTAssertNil(speech.capturedLocalWindowID(for: id))
        speech.cancel()
        XCTAssertNil(speech.capturedLocalWindowID(for: id))
    }

    func testLocalHandoffAndWorkShareTurnIdentity() async throws {
        let (controller, c) = tracedComposition()
        controller.submitTypedCommand("show Google Chrome")
        await waitFor { c.tasks.first?.active == false }
        let work = try XCTUnwrap(c.tasks.first)
        XCTAssertEqual(work.outcome, .done)
        let events = controller.commandTrace.events
        let turn = try XCTUnwrap(work.captureID)
        XCTAssertTrue(events.contains { $0.turn == turn && $0.stage == .localBegin })
        XCTAssertTrue(events.contains { $0.turn == turn && $0.task == work.id && $0.stage == .workCreated })
        XCTAssertTrue(events.contains { $0.turn == turn && $0.task == work.id && $0.stage == .driverEnd })
        XCTAssertTrue(events.contains { $0.turn == turn && $0.stage == .gazeBegin })
        XCTAssertTrue(events.contains { $0.turn == turn && $0.stage == .gazeEnd })
    }

    func testDriverSuccessFailureCategoriesAndPrivateSentinels() async throws {
        let (controller, c) = tracedComposition(failing: true)
        controller.submitTypedCommand("show Google Chrome")
        await waitFor { c.tasks.first?.active == false }
        XCTAssertTrue(controller.commandTrace.events.contains { $0.stage == .driverFailed })
        let data = try JSONSerialization.data(withJSONObject: controller.commandTrace.snapshot(since: 0))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SensitiveSentinelValue"))
    }

    func testCoordinatorAwaitBeginEndAndCancellation() async {
        let (controller, c) = tracedComposition()
        var resume: CheckedContinuation<String?, Never>?
        c.gazeContextProvider = { await withCheckedContinuation { resume = $0 } }
        controller.submitTypedCommand("show Google Chrome")
        await waitFor { resume != nil }
        XCTAssertTrue(c.tasks.isEmpty)
        XCTAssertEqual(controller.commandTrace.events.last?.stage, .gazeBegin)
        controller.cancelCaptureAttempt()
        resume?.resume(returning: nil)
        await waitFor { controller.commandTrace.events.contains { $0.stage == .gazeEnd } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(c.tasks.isEmpty, "cancelled admission cannot create a later task")
        XCTAssertTrue(controller.commandTrace.events.contains { $0.stage == .cancelled })
        XCTAssertFalse(controller.commandTrace.events.contains { $0.stage == .workCreated || $0.stage == .driverBegin })
    }

    func testSemanticProposalNeverCallsOrdinaryCommandHandler() async throws {
        let c = context(), lane = lane(c)
        lane.semanticEnabled = { true }
        var requests = 0, confirmations = 0, actions = 0
        lane.semanticInterpretation = { admission, context in
            requests += 1
            let request = try VoiceSemanticRouter.request(admission.text, context: context)
            return try VoiceSemanticRouter.decode(self.response(), request: request, turn: admission.turn)
        }
        lane.semanticConfirmationHandler = { proposal in
            XCTAssertEqual(proposal.target, c.entities[0])
            confirmations += 1
            return true
        }
        lane.commandHandler = { _, _, _, _, _, _ in actions += 1; return "{}" }
        try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
        XCTAssertEqual(requests, 1); XCTAssertEqual(confirmations, 1); XCTAssertEqual(actions, 0)
        lane.cancel()
    }

    func testChangedContextCannotCreateSemanticWork() async throws {
        var current = context()
        let lane = lane(current)
        lane.semanticEnabled = { true }
        lane.semanticContextProvider = { current }
        lane.semanticInterpretation = { admission, captured in
            current.targetID = "another.window"
            return .proposal(.init(turn: admission.turn, target: captured.entities[0],
                                   model: "fixture", actionConfidence: 1, targetConfidence: 1))
        }
        lane.semanticConfirmationHandler = { _ in XCTFail("stale context"); return true }
        try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
        lane.cancel()
    }

    func testLateCancelledInterpretationCannotCreateWork() async throws {
        let lane = lane(context())
        lane.semanticEnabled = { true }
        var waiter: CheckedContinuation<VoiceSemanticRouter.Outcome, Error>?
        lane.semanticInterpretation = { _, _ in try await withCheckedThrowingContinuation { waiter = $0 } }
        lane.semanticConfirmationHandler = { _ in XCTFail("cancelled proposal"); return true }
        let task = Task { try await lane.submitTyped("I need my web browser over here", sessionID: UUID()) }
        await waitFor { waiter != nil }
        lane.cancel()
        waiter?.resume(returning: .noMatch)
        _ = try? await task.value
    }

    func testDisableReenableDuringFreshnessCannotReviveProposal() async throws {
        let c = context(), lane = lane(context())
        var enabled = true, ended = false
        var fresh: CheckedContinuation<VoiceAdmissionContext, Never>?
        lane.semanticEnabled = { enabled }
        lane.semanticContextProvider = { await withCheckedContinuation { fresh = $0 } }
        lane.semanticInterpretation = { admission, captured in
            .proposal(.init(turn: admission.turn, target: captured.entities[0],
                            model: "fixture", actionConfidence: 1, targetConfidence: 1))
        }
        lane.semanticConfirmationHandler = { _ in XCTFail("disabled result revived"); return true }
        let task = Task {
            try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
            ended = true
        }
        await waitFor { fresh != nil }
        enabled = false; lane.cancelSemanticInterpretation(); enabled = true
        await waitFor { ended }
        fresh?.resume(returning: c)
        _ = try? await task.value
        lane.cancel()
    }

    func testReplacementTurnWithSameUUIDRetainsItsAuthority() async throws {
        let c = context(), lane = lane(context()), id = UUID()
        lane.semanticEnabled = { true }
        var waiters: [CheckedContinuation<VoiceSemanticRouter.Outcome, Error>] = []
        var newEnded = false
        lane.semanticInterpretation = { _, _ in
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        lane.semanticConfirmationHandler = { _ in XCTFail("abandoned interpretation"); return true }
        let old = Task { try await lane.submitTyped("I need my web browser over here", sessionID: id) }
        await waitFor { waiters.count == 1 }
        let new = Task {
            try await lane.submitTyped("I need my web browser over here", sessionID: id)
            newEnded = true
        }
        await waitFor { waiters.count == 2 }
        waiters[0].resume(returning: .proposal(.init(
            turn: VoiceTurnToken(id: id, generation: 1, mode: .typed), target: c.entities[0],
            model: "fixture", actionConfidence: 1, targetConfidence: 1)))
        _ = try? await old.value
        lane.cancelSemanticInterpretation()
        await waitFor { newEnded }
        waiters[1].resume(returning: .noMatch)
        _ = try? await new.value
        lane.cancel()
    }

    /// Expires the semantic wall by hand once the interpretation is waiting,
    /// and records the deadline the lane asked for.
    private func manualDeadline(_ lane: RealtimeVoiceLane) -> (requested: LockedBox<TimeInterval?>, fire: () -> Void) {
        let requested = LockedBox<TimeInterval?>(nil)
        let (fired, fire) = AsyncStream<Void>.makeStream()
        lane.semanticDeadline = { deadline in
            requested.set(deadline)
            for await _ in fired { return }
        }
        return (requested, { _ = fire.yield() })
    }

    /// The wall the lane armed is four seconds from the hop's start.
    private func assertFourSecondWall(_ requested: TimeInterval?, between before: TimeInterval, and after: TimeInterval,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = try XCTUnwrap(requested, "the hop must arm its wall", file: file, line: line)
        XCTAssertEqual(RealtimeVoiceLane.semanticWall, 4, file: file, line: line)
        XCTAssertGreaterThanOrEqual(deadline, before + 4, file: file, line: line)
        XCTAssertLessThanOrEqual(deadline, after + 4, file: file, line: line)
    }

    func testSemanticWatchdogDiscardsLateResult() async throws {
        let c = context(), lane = lane(context())
        lane.semanticEnabled = { true }
        let (requested, fire) = manualDeadline(lane)
        var waiter: CheckedContinuation<VoiceSemanticRouter.Outcome, Error>?
        var captured: VoiceAdmission?
        lane.semanticInterpretation = { input, _ in
            captured = input
            return try await withCheckedThrowingContinuation { waiter = $0; fire() }
        }
        lane.semanticConfirmationHandler = { _ in XCTFail("late model result"); return true }
        let before = ProcessInfo.processInfo.systemUptime
        try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
        try assertFourSecondWall(requested.value, between: before, and: ProcessInfo.processInfo.systemUptime)
        let input = try XCTUnwrap(captured)
        waiter?.resume(returning: .proposal(.init(turn: input.turn, target: c.entities[0],
            model: "fixture", actionConfidence: 1, targetConfidence: 1)))
        lane.cancel()
    }

    /// Fixed numeric categories on `semantic.failed`. The existing diagnostic
    /// channel carries `[String: Double]`, so a category is a code — never a
    /// message, request, target identity or credential.
    private enum SemanticFailure {
        static let deadline = 1.0, transport = 2.0, budget = 3.0, cancelled = 4.0
    }
    private static let semanticMetricKeys: Set<String> = [
        "reserve_ms", "infer_ms", "fresh_context_ms", "interpret_ms", "failure",
        "action_confidence", "target_confidence"
    ]
    private static let semanticTerminalStages: Set<String> = [
        "semantic.no_match", "semantic.clarify", "semantic.proposal", "semantic.failed"
    ]

    /// Every semantic turn ends in exactly one terminal stage, ordered after
    /// `semantic.begin`, carrying only allow-listed finite numeric metrics.
    private func terminal(_ events: [VoiceSpeechDiagnostic],
                          file: StaticString = #filePath, line: UInt = #line) throws -> VoiceSpeechDiagnostic {
        let begun = try XCTUnwrap(events.first { $0.stage == "semantic.begin" }, file: file, line: line)
        let ended = events.filter { Self.semanticTerminalStages.contains($0.stage) }
        XCTAssertEqual(ended.count, 1, "one terminal semantic stage per turn", file: file, line: line)
        for event in events {
            XCTAssertTrue(Self.semanticMetricKeys.isSuperset(of: event.metrics.keys),
                          "unexpected telemetry key in \(event.stage)", file: file, line: line)
            XCTAssertTrue(event.metrics.values.allSatisfy { $0.isFinite && $0 >= 0 },
                          "stage durations are monotonic milliseconds", file: file, line: line)
            XCTAssertGreaterThanOrEqual(event.monotonic, begun.monotonic, file: file, line: line)
        }
        return try XCTUnwrap(ended.last, file: file, line: line)
    }

    func testExpiredSemanticHopReportsDeadlineCategoryAndMeasuredWall() async throws {
        let lane = lane(context())
        lane.semanticEnabled = { true }
        var events: [VoiceSpeechDiagnostic] = []
        lane.onDiagnostic = { if $0.stage.hasPrefix("semantic.") { events.append($0) } }
        let (requested, fire) = manualDeadline(lane)
        var waiter: CheckedContinuation<VoiceSemanticRouter.Outcome, Error>?
        lane.semanticInterpretation = { _, _ in try await withCheckedThrowingContinuation { waiter = $0; fire() } }
        lane.semanticConfirmationHandler = { _ in XCTFail("expired interpretation"); return true }
        let before = ProcessInfo.processInfo.systemUptime
        try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
        let after = ProcessInfo.processInfo.systemUptime
        try assertFourSecondWall(requested.value, between: before, and: after)
        let failed = try terminal(events)
        XCTAssertEqual(failed.stage, "semantic.failed")
        XCTAssertEqual(failed.metrics["failure"], SemanticFailure.deadline,
                       "an expired wall is not a transport or budget failure")
        let interpret = try XCTUnwrap(failed.metrics["interpret_ms"], "the expired stage must be measured")
        XCTAssertLessThanOrEqual(interpret, (after - before) * 1000, "the stage is measured inside the turn")
        XCTAssertNil(failed.metrics["fresh_context_ms"], "fresh context never ran")
        waiter?.resume(returning: .noMatch)
        lane.cancel()
    }

    func testTransportFailuresReportTransportCategoryWithoutWaitingOnTheWall() async throws {
        for failure in [VoiceSemanticRouter.Failure.unavailable as Error, URLError(.timedOut) as Error] {
            let lane = lane(context())
            lane.semanticEnabled = { true }
            var events: [VoiceSpeechDiagnostic] = []
            lane.onDiagnostic = { if $0.stage.hasPrefix("semantic.") { events.append($0) } }
            lane.semanticInterpretation = { _, _ in throw failure }
            lane.semanticConfirmationHandler = { _ in XCTFail("failed interpretation"); return true }
            let started = ProcessInfo.processInfo.systemUptime
            try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
            let failed = try terminal(events)
            XCTAssertEqual(failed.stage, "semantic.failed")
            XCTAssertEqual(failed.metrics["failure"], SemanticFailure.transport, "\(failure)")
            let interpret = try XCTUnwrap(failed.metrics["interpret_ms"], "\(failure)")
            XCTAssertLessThan(interpret, 3000)
            XCTAssertNil(failed.metrics["fresh_context_ms"])
            lane.cancel()
        }
    }

    func testCancelledInterpretationReportsCancellationNotDeadlineAndCreatesNoWork() async throws {
        let lane = lane(context())
        lane.semanticEnabled = { true }
        var events: [VoiceSpeechDiagnostic] = []
        lane.onDiagnostic = { if $0.stage.hasPrefix("semantic.") { events.append($0) } }
        var waiter: CheckedContinuation<VoiceSemanticRouter.Outcome, Error>?
        var actions = 0
        lane.semanticInterpretation = { _, _ in try await withCheckedThrowingContinuation { waiter = $0 } }
        lane.semanticConfirmationHandler = { _ in XCTFail("cancelled proposal"); return true }
        lane.commandHandler = { _, _, _, _, _, _ in actions += 1; return "{}" }
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task { try await lane.submitTyped("I need my web browser over here", sessionID: UUID()) }
        await waitFor { waiter != nil }
        lane.cancelSemanticInterpretation()
        _ = try? await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3, "cancellation does not wait on the wall")
        let failed = try terminal(events)
        XCTAssertEqual(failed.stage, "semantic.failed")
        XCTAssertEqual(failed.metrics["failure"], SemanticFailure.cancelled,
                       "cancellation is never reported as an expired wall")
        XCTAssertEqual(actions, 0)
        waiter?.resume(returning: .noMatch)
        lane.cancel()
    }

    /// The production router drives the lane; only the transport is a fixture.
    /// Reservation, inference and fresh-context capture are timed separately
    /// so the dominant stage is nameable without relaxing any cap.
    func testSemanticProposalRecordsReserveInferenceAndFreshContextDurations() async throws {
        let c = context(), lane = lane(c)
        let reply = try response()
        let router = VoiceSemanticRouter.live(apiKey: "fixture-key", transport: { _, questions in
            XCTAssertEqual(Set(questions.keys), ["operation"])
            try? await Task.sleep(nanoseconds: 150_000_000)
            return reply
        })
        var events: [VoiceSpeechDiagnostic] = []
        lane.onDiagnostic = { if $0.stage.hasPrefix("semantic.") { events.append($0) } }
        lane.semanticEnabled = { true }
        lane.semanticContextProvider = {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return c
        }
        lane.semanticInterpretation = { admission, context in
            try await router.interpret(admission, context: context)
        }
        var confirmations = 0
        lane.semanticConfirmationHandler = { proposal in
            XCTAssertEqual(proposal.target, c.entities[0])
            confirmations += 1
            return true
        }
        let started = ProcessInfo.processInfo.systemUptime
        try await lane.submitTyped("I need my web browser over here", sessionID: UUID())
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        XCTAssertEqual(confirmations, 1, "stage telemetry does not change the outcome or its target")
        let proposed = try terminal(events)
        XCTAssertEqual(proposed.stage, "semantic.proposal")
        XCTAssertEqual(proposed.metrics["action_confidence"], 1)
        XCTAssertEqual(proposed.metrics["target_confidence"], 1)
        let infer = try XCTUnwrap(proposed.metrics["infer_ms"], "inference must be timed")
        let reserve = try XCTUnwrap(proposed.metrics["reserve_ms"], "reservation must be timed, zero when skipped")
        let fresh = try XCTUnwrap(proposed.metrics["fresh_context_ms"], "fresh context must be timed")
        let interpret = try XCTUnwrap(proposed.metrics["interpret_ms"], "the whole hop must be timed")
        XCTAssertGreaterThanOrEqual(infer, 140)
        XCTAssertGreaterThanOrEqual(fresh, 90)
        XCTAssertGreaterThanOrEqual(interpret, infer + reserve - 1, "the hop covers reservation and inference")
        XCTAssertLessThanOrEqual(interpret + fresh, elapsed + 250, "durations stay inside the measured turn")
        XCTAssertNil(proposed.metrics["failure"], "a proposal has no failure category")
        lane.cancel()
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func coordinator() -> (VoiceTaskCoordinator, Config) {
        let config = Config(defaults: UserDefaults(suiteName: "semantic-\(UUID())")!,
            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        XCTAssertTrue(config.semanticAppSuggestions)
        config.semanticAppSuggestions = true; config.alwaysAllowComputerUse = true; config.sounds = false
        let c = VoiceTaskCoordinator(config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay())
        return (c, config)
    }

    func testAuditScopedCancelPreservesUnrelatedWorkAndGlobalHook() async {
        let (c, config) = coordinator()
        let controller = VoiceController.inert(config: config, authorize: { false }, cuaRuntime: c)
        let unrelated = VoiceTaskCoordinator.Work(label: "Other task", request: "Other task",
            spec: DriveTask(goal: "Other task"))
        c.tasks.append(unrelated)
        var globalStops = 0
        controller.cancelAllTasks = { globalStops += 1; _ = await c.cancelAllRunning() }
        controller.cancelCaptureAttempt()
        await Task.yield()
        XCTAssertEqual(globalStops, 0)
        XCTAssertTrue(unrelated.active)
        controller.cancel()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(globalStops, 1, "normal Escape behavior remains universal")
    }

    func testInstructionAuthorizesFocusWithoutAskOrStandingGrant() async throws {
        let (c, config) = coordinator()
        config.alwaysAllowComputerUse = false
        let input = try await admission()
        let proposal = VoiceSemanticRouter.Proposal(turn: input.turn, target: context().entities[0],
            model: "protocol-fixture", actionConfidence: 1, targetConfidence: 1)
        var actions = 0
        XCTAssertTrue(c.offerSemanticFocus(proposal, validate: { true }, runConfirmed: { work in
            XCTAssertEqual(work.spec.application, proposal.target.id)
            actions += 1; work.active = false
        }))
        await waitFor { actions == 1 }
        let work = try XCTUnwrap(c.tasks.last)
        XCTAssertFalse(work.awaitingAnswer)
        XCTAssertFalse(work.awaitingApproval)
        XCTAssertNil(work.ask)
        XCTAssertEqual(actions, 1)
    }

    func testLowConfidenceCannotCreateAppFocusWorkOrApproval() async throws {
        let (c, _) = coordinator()
        let input = try await admission()
        for confidence in [0.0, 0.89, Double.nan, 1.01] {
            let p = VoiceSemanticRouter.Proposal(turn: input.turn, target: context().entities[0],
                model: "fixture", actionConfidence: confidence, targetConfidence: confidence)
            XCTAssertFalse(c.offerSemanticFocus(p, validate: { true }, runConfirmed: { _ in XCTFail("uncertain execution") }))
        }
        XCTAssertTrue(c.tasks.isEmpty)
        let speech = lane(context())
        speech.semanticEnabled = { true }
        speech.semanticInterpretation = { input, captured in
            .proposal(.init(turn: input.turn, target: captured.entities[0], model: "fixture",
                            actionConfidence: 0.5, targetConfidence: 0.5))
        }
        speech.semanticConfirmationHandler = { _ in XCTFail("low confidence cannot reach execution admission"); return false }
        try await speech.submitTyped(input.text, sessionID: UUID())
        speech.cancel()
    }

    func testDisappearedTargetNeverExecutesWithoutConfirmation() async throws {
        let (c, _) = coordinator()
        let input = try await admission()
        let p = VoiceSemanticRouter.Proposal(turn: input.turn, target: context().entities[0],
            model: "fixture", actionConfidence: 1, targetConfidence: 1)
        XCTAssertTrue(c.offerSemanticFocus(p, validate: { false }, runConfirmed: { _ in XCTFail("must not execute") }))
        let work = try XCTUnwrap(c.tasks.last)
        await waitFor { !work.active }
        XCTAssertFalse(work.awaitingAnswer)
    }

    func testCancellationAndDisableDuringValidationDoNotExecute() async throws {
        for disable in [false, true] {
            let (c, config) = coordinator()
            var resume: CheckedContinuation<Bool, Never>?
            let input = try await admission()
            let proposal = VoiceSemanticRouter.Proposal(turn: input.turn, target: context().entities[0],
                model: "fixture", actionConfidence: 1, targetConfidence: 1)
            XCTAssertTrue(c.offerSemanticFocus(proposal,
                validate: { await withCheckedContinuation { resume = $0 } },
                runConfirmed: { _ in XCTFail("cancelled/disabled suggestion executed") }))
            let work = try XCTUnwrap(c.tasks.last)
            await waitFor { resume != nil }
            if disable {
                config.semanticAppSuggestions = false
                c.cancelPendingSemanticFocus()
            } else { c.cancel(work.id) }
            resume?.resume(returning: true)
            await waitFor { !work.active }
            XCTAssertFalse(work.awaitingAnswer)
        }
    }

    func testTypedFocusNeverParsesDisplayNameAsCommand() async {
        var tools: [String] = []
        let loop = DriveLoop.inert(call: { tool, _ in
            tools.append(tool)
            if tool == "bring_to_front" {
                return .object(["activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])])
            }
            return .object(["windows": .array([.object([
                "window_id": .number(7), "is_on_screen": .bool(true), "title": .string("Fixture")
            ])])])
        }, choose: { _, _ in XCTFail("semantic focus never invokes another model"); return nil },
        ask: nil, granted: { true }, resolver: AppResolver.fixture(listApps: {
            [.init(name: "open a new tab", bundle: "fixture.target", pid: 42)]
        }), appIsHidden: { _ in false }, activateRestoredApp: { _, _ in })
        let task = DriveTask(goal: "Focus confirmed application", application: "fixture.target",
                             scope: .open, foreground: true)
        let result = await loop.runAppFocus(bundleID: "fixture.target", task: task, session: "fixture")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(tools.filter { $0 == "bring_to_front" }.count, 1)
        XCTAssertFalse(tools.contains { ["press_key", "type_text", "browser_navigate"].contains($0) })
    }

    func testInstructionDispatchSelectsTypedExecutorOnceWithoutApproval() async throws {
        let (c, _) = coordinator()
        var mutations = 0
        let loop = DriveLoop.inert(call: { tool, args in
            if tool == "bring_to_front" {
                mutations += 1
                XCTAssertEqual(args["pid"], .number(42))
                return .object(["activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])])
            }
            return .object(["windows": .array([.object([
                "window_id": .number(7), "is_on_screen": .bool(true), "title": .string("Fixture")
            ])])])
        }, choose: { _, _ in XCTFail("generic chooser must not run"); return nil },
        ask: nil, granted: { true }, resolver: AppResolver.fixture(listApps: {
            [.init(name: "open a new tab", bundle: "fixture.target", pid: 42)]
        }), appIsHidden: { _ in false }, activateRestoredApp: { _, _ in })
        let input = try await admission()
        let target = VoiceAdmissionContext.Entity(name: "open a new tab", id: "fixture.target", canOpenLocally: true)
        let proposal = VoiceSemanticRouter.Proposal(turn: input.turn, target: target,
            model: "fixture", actionConfidence: 1, targetConfidence: 1)
        XCTAssertTrue(c.offerSemanticFocus(proposal, validate: { true }, driverLoop: loop))
        let work = try XCTUnwrap(c.tasks.last)
        await waitFor { !work.active }
        XCTAssertFalse(work.awaitingAnswer)
        XCTAssertFalse(work.awaitingApproval)
        XCTAssertEqual(work.outcome, .done)
        XCTAssertEqual(mutations, 1)
        XCTAssertTrue(work.dispatchedEffect)
    }
}

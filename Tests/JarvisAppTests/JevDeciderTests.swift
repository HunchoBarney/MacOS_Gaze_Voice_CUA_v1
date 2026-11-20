import CoreGraphics
import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: `JevDecider` adapts the existing bounded candidate pick to
/// `DecideResult` — it selects among candidates, returns requests, and
/// never actuates. Literal text only ever comes from the caller's own
/// `values` or a parked ask answer; the model chooses fields, it never
/// authors text.
final class JevDeciderTests: XCTestCase {

    /// A pick queue behind the existing `DriveLoop.Choose` shape — the
    /// same factory `JevChooser.make` produces in production.
    final class FakeChoose: @unchecked Sendable {
        var picks: [DriveLoop.JevChoice?] = []
        var states: [JSONValue] = []
        var candidateSets: [[String]] = []
        var error: Error?
    }

    private func makeDecider(_ fake: FakeChoose) -> JevDecider {
        JevDecider(choose: { state, candidates in
            if let error = fake.error { throw error }
            fake.states.append(state)
            fake.candidateSets.append(candidates.map { $0.id })
            guard !fake.picks.isEmpty else { return nil }
            return fake.picks.removeFirst()
        })
    }

    private func element(_ index: Int, role: String = "AXButton",
                         label: String, value: String? = nil,
                         token: String? = nil,
                         actions: [String] = ["AXPress"]) -> AXElement {
        AXElement(index: index, token: token, role: role, label: label,
                  value: value,
                  frame: CGRect(x: 10, y: 10, width: 80, height: 24),
                  actions: actions)
    }

    private func obs(_ elements: [AXElement], title: String = "Fixture",
                     task: TaskBrief? = nil, history: [RoundRecord] = [],
                     snapshotID: String? = "snap-1") -> TaskObservation {
        TaskObservation(stepIndex: 0,
                        axSnapshot: AXSnapshot(windowTitle: title,
                                               snapshotID: snapshotID,
                                               elements: elements,
                                               treeMarkdown: ""),
                        task: task ?? TaskBrief(goal: "press save"),
                        history: history,
                        budget: RoundBudget(roundsRemaining: 4,
                                            millisecondsRemaining: nil))
    }

    // MARK: - pick → request mapping

    func testBlankFieldAndCompleteHistoryReachJudgment() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
        let history = (0..<10).map {
            RoundRecord(stepIndex: $0, echo: .act, summary: "Finished stage \($0)",
                        actuated: true, settleVerified: true)
        }
        _ = try await makeDecider(fake).nextStep(obs([
            element(1, role: "AXTextField", label: "Search", value: ""),
            element(2, role: "AXSecureTextField", label: "Password", value: "private"),
        ], history: history))
        let state = try XCTUnwrap(fake.states.first)
        XCTAssertTrue(state["screen_values"]?.string?.contains("Search=") == true)
        XCTAssertFalse(state["screen_values"]?.string?.contains("private") == true)
        XCTAssertFalse(state["observed_content"]?.string?.contains("private") == true)
        XCTAssertEqual(state["recent_steps"]?.array?.count, 10)
    }

    func testCallerLiteralComparisonKeepsUnknownDistinctFromMismatch() async throws {
        for value in [Optional("Aster"), Optional("Old"), Optional(""), nil] {
            let fake = FakeChoose()
            fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
            _ = try await makeDecider(fake).nextStep(obs([
                element(1, role: "AXTextField", label: "Name", value: value),
            ], task: TaskBrief(goal: "Enter the supplied name", values: ["Name": "Aster"])))
            let match = fake.states.first?["_candidate_details"]?["t1"]?["literal_matches_current_value"]
            if let value { XCTAssertEqual(match, .bool(value == "Aster")) }
            else { XCTAssertNil(match) }
        }
    }

    func testObservedBoundsAreKnownOrExplicitlyUnknown() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
        _ = try await makeDecider(fake).nextStep(obs([
            AXElement(index: 1, token: nil, role: "AXButton", label: "Continue", value: nil,
                      frame: .init(x: 10, y: 20, width: 100, height: 30), actions: ["AXPress"]),
            AXElement(index: 2, token: nil, role: "AXButton", label: "Continue", value: nil,
                      frame: nil, actions: ["AXPress"]),
        ], task: TaskBrief(goal: "Press the left Continue")))
        let details = fake.states.first?["_candidate_details"]
        XCTAssertEqual(details?["e1"]?["bounds"], .object([
            "x": .number(10), "y": .number(20), "width": .number(100), "height": .number(30),
        ]))
        XCTAssertEqual(details?["e2"]?["bounds"], .null)
    }

    func testAllSnapshotControlsRemainAvailableByDefault() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
        _ = try await makeDecider(fake).nextStep(obs(
            (0..<45).map { element($0, label: "Option \($0)") }))
        XCTAssertTrue(fake.candidateSets[0].contains("e44"))
    }

    func testAnsweredQuestionDoesNotBlockAnotherField() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil),
                      .init(id: "t5", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let fields = [element(4, role: "AXTextField", label: "Name"),
                      element(5, role: "AXTextField", label: "Email")]
        guard case .askUser(let firstQuestion, _) = try await decider.nextStep(obs(fields)) else {
            return XCTFail("expected first field question")
        }
        let first = RoundRecord(stepIndex: 0, echo: .ask, summary: firstQuestion,
                                askKind: .question, askQuestion: firstQuestion, askAnswer: "Alice")
        guard case .act(let name) = try await decider.nextStep(obs(fields, history: [first])) else {
            return XCTFail("expected first field entry")
        }
        XCTAssertEqual(name.args["text"], .string("Alice"))
        let entered = RoundRecord(stepIndex: 1, echo: .act, summary: "Name entered",
                                  actuated: true, settleVerified: true)
        let filled = [element(4, role: "AXTextField", label: "Name", value: "Alice"),
                      element(5, role: "AXTextField", label: "Email", value: "")]
        guard case .askUser(let secondQuestion, _) = try await decider.nextStep(
            obs(filled, history: [first, entered])) else {
            return XCTFail("an answered Name question must not block the Email question")
        }
        let second = RoundRecord(stepIndex: 2, echo: .ask, summary: secondQuestion,
                                 askKind: .question, askQuestion: secondQuestion,
                                 askAnswer: "alice@example.test")
        guard case .act(let email) = try await decider.nextStep(
            obs(filled, history: [first, entered, second])) else {
            return XCTFail("expected second field entry")
        }
        XCTAssertEqual(email.args["text"], .string("alice@example.test"))
        XCTAssertNotEqual(email.args["text"], name.args["text"])
    }

    func testParkedFieldRejectsAnotherQuestionsAnswer() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let fields = [element(4, role: "AXTextField", label: "Name")]
        _ = try await decider.nextStep(obs(fields))
        let unrelated = RoundRecord(stepIndex: 0, echo: .ask, summary: "Different field?",
                                    askKind: .question, askQuestion: "Different field?",
                                    askAnswer: "must not be typed")
        guard case .blocked = try await decider.nextStep(obs(fields, history: [unrelated])) else {
            return XCTFail("a parked Name request cannot consume a different question's answer")
        }
    }

    func testTextQuestionDoesNotExposeSecureCurrentValue() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let result = try await makeDecider(fake).nextStep(obs([
            element(4, role: "AXSecureTextField", label: "Password", value: "old-private-value")
        ]))
        guard case .askUser(let question, _) = result else {
            return XCTFail("expected literal question")
        }
        XCTAssertTrue(question.contains("Password"))
        XCTAssertFalse(question.contains("old-private-value"))
    }

    /// A press pick becomes an `.act` request — element_token authority
    /// when the snapshot minted one, never an index guess.
    func testElementPickBeatsActWithToken() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "e3", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([
            element(3, label: "Save", token: "tok-abc")]))
        guard case .act(let request) = result else {
            return XCTFail("expected .act, got \(result)")
        }
        XCTAssertEqual(request.effect, .tool)
        XCTAssertEqual(request.tool, "click")
        XCTAssertEqual(request.args["element_token"], .string("tok-abc"))
        XCTAssertNil(request.args["element_index"])
        XCTAssertEqual(request.elementText, "Save")
        // The decider addresses elements only — the loop stamps the
        // captured window it owns.
        XCTAssertNil(request.args["pid"])
        XCTAssertNil(request.args["window_id"])
    }

    /// Without a token the request binds element_index plus the
    /// snapshot's own id — position never stands alone.
    func testElementPickFallsBackToIndexAndSnapshot() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "e3", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([
            element(3, label: "Save")], snapshotID: "snap-9"))
        guard case .act(let request) = result else {
            return XCTFail("expected .act, got \(result)")
        }
        XCTAssertEqual(request.args["element_index"], .number(3))
        XCTAssertEqual(request.args["snapshot_id"], .string("snap-9"))
    }

    /// The reserved picks map verbatim — done, reobserve, abstain.
    func testDonePickReturnsDone() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "done", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .done = result else {
            return XCTFail("expected .done, got \(result)")
        }
    }

    /// A same-call done vote routes through the done candidate exactly
    /// like a done pick — the loop's verify_state gate applies either way.
    func testDoneVoteRoutesToDone() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "e1", confidence: 0.9, doneVote: true)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .done = result else {
            return XCTFail("expected .done, got \(result)")
        }
    }

    func testReobservePickReturnsReobserve() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .act(let request) = result else {
            return XCTFail("expected .act, got \(result)")
        }
        XCTAssertEqual(request.effect, .reobserve)
    }

    func testStuckPickBlocks() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "stuck", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .blocked = result else {
            return XCTFail("expected .blocked, got \(result)")
        }
    }

    // MARK: - retry gates → escalation

    /// An unusable pick re-observes once; a second one escalates — the
    /// decider burns its bounded retries then hands up, never guesses.
    func testInvalidPicksEscalateAfterBound() async throws {
        let fake = FakeChoose()
        fake.picks = [
            .init(id: "not-a-candidate", confidence: nil, doneVote: nil),
            .init(id: "still-not", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let first = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .act(let req) = first, req.effect == .reobserve else {
            return XCTFail("expected reobserve, got \(first)")
        }
        let second = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .escalate(.invalidChoice) = second else {
            return XCTFail("expected .escalate(.invalidChoice), got \(second)")
        }
    }

    /// A nil pick is an unusable answer too — same bounded retry.
    func testNilPickCountsAsInvalid() async throws {
        let fake = FakeChoose()
        fake.picks = [nil, nil]
        let decider = makeDecider(fake)
        _ = try await decider.nextStep(obs([element(1, label: "Save")]))
        let second = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .escalate(.invalidChoice) = second else {
            return XCTFail("expected .escalate(.invalidChoice), got \(second)")
        }
    }

    /// Below the confidence floor a pick is a guess — one re-observe,
    /// then the lowConfidenceTwice escalation the contract names.
    func testLowConfidenceTwiceEscalates() async throws {
        let fake = FakeChoose()
        fake.picks = [
            .init(id: "e1", confidence: 0.2, doneVote: nil),
            .init(id: "e1", confidence: 0.3, doneVote: nil)]
        let decider = makeDecider(fake)
        let first = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .act(let req) = first, req.effect == .reobserve else {
            return XCTFail("expected reobserve, got \(first)")
        }
        let second = try await decider.nextStep(obs([element(1, label: "Save")]))
        guard case .escalate(.lowConfidenceTwice) = second else {
            return XCTFail("expected .escalate(.lowConfidenceTwice), got \(second)")
        }
    }

    /// A degraded snapshot escalates honestly — the decider can't pick
    /// what it can't see.
    func testDegradedAXEscalates() async throws {
        let fake = FakeChoose()
        let decider = makeDecider(fake)
        var o = obs([element(1, label: "Save")])
        o.axSnapshot = nil
        let result = try await decider.nextStep(o)
        guard case .escalate(.degradedAX) = result else {
            return XCTFail("expected .escalate(.degradedAX), got \(result)")
        }
        XCTAssertTrue(fake.states.isEmpty)  // never asked the model
    }

    /// A screen that stopped changing is a loop-recorded fact — three
    /// trailing stale records escalate, mirroring the stale-round stop.
    func testStaleScreenEscalates() async throws {
        let fake = FakeChoose()
        let decider = makeDecider(fake)
        let stale = (0..<3).map { i in
            RoundRecord(stepIndex: i, echo: .act, summary: "press Save",
                        staleScreen: true)
        }
        let result = try await decider.nextStep(
            obs([element(1, label: "Save")], history: stale))
        guard case .escalate(.staleScreen) = result else {
            return XCTFail("expected .escalate(.staleScreen), got \(result)")
        }
    }

    /// The first capture after a real dispatch can precede the app's
    /// repaint/AX propagation — delivery in flight, not a stale screen.
    /// The decider re-observes once instead of acting on a pre-delivery
    /// view, and the stillness clock restarts from there.
    func testDeliveredEffectInFlightReobservesBeforeStaleCounts() async throws {
        let fake = FakeChoose()
        fake.picks = (0..<4).map { _ in .init(id: "e1", confidence: nil, doneVote: nil) }
        let decider = makeDecider(fake)
        let elements = [element(1, label: "Save")]
        guard case .act = try await decider.nextStep(obs(elements)) else {
            return XCTFail("expected the Save pick to dispatch")
        }
        var history: [RoundRecord] = [
            .init(stepIndex: 0, echo: .act, summary: "press Save", actuated: true),
        ]
        var after = obs(elements, history: history)
        after.stepIndex = 1
        guard case .act(let wait) = try await decider.nextStep(after),
              wait.effect == .reobserve else {
            return XCTFail("expected reobserve on the in-flight round")
        }
        history.append(.init(stepIndex: 1, echo: .reobserve, summary: wait.summary))
        // The streak restarted: three further identical captures before
        // the stale stop fires — delivery lag gets a bounded window, a
        // truly-stuck screen still escalates.
        for step in 2...4 {
            var later = obs(elements, history: history)
            later.stepIndex = step
            let result = try await decider.nextStep(later)
            if step < 4 {
                guard case .act = result else {
                    return XCTFail("step \(step): expected act, got \(result)")
                }
            } else {
                guard case .escalate(.staleScreen) = result else {
                    return XCTFail("step \(step): expected staleScreen, got \(result)")
                }
            }
            history.append(.init(stepIndex: step, echo: .reobserve, summary: "wait"))
        }
    }

    // MARK: - literal text authority

    /// Type candidates carry the caller's literal verbatim — the model
    /// selected the field; the text was already the user's.
    func testTypePickUsesLiteralVerbatim() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        var brief = TaskBrief(goal: "type my name")
        brief.values["text"] = "Karan V."
        let result = try await decider.nextStep(obs([
            element(4, role: "AXTextField", label: "Name", token: "tok-4")],
            task: brief))
        guard case .act(let request) = result else {
            return XCTFail("expected .act, got \(result)")
        }
        XCTAssertEqual(request.tool, "type_text")
        XCTAssertEqual(request.args["text"], .string("Karan V."))
        XCTAssertEqual(request.args["element_token"], .string("tok-4"))
    }

    func testReplacementPickUsesCallerLiteralAndOriginalToken() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "v4", confidence: nil, doneVote: nil)]
        let literal = "New body\nWith literal punctuation."
        let brief = TaskBrief(goal: "Replace all document text", values: ["text": literal])
        let result = try await makeDecider(fake).nextStep(obs([
            element(4, role: "AXTextArea", label: "Document", value: "Old body", token: "tok-4"),
        ], task: brief))
        guard case .act(let request) = result else {
            return XCTFail("expected replacement action, got \(result)")
        }
        XCTAssertEqual(request.tool, "set_value")
        XCTAssertEqual(request.args["value"], .string(literal))
        XCTAssertNil(request.args["text"])
        XCTAssertNil(request.args["delivery_mode"])
        XCTAssertEqual(request.args["element_token"], .string("tok-4"))
    }

    func testReplacementQuestionAnswerUsesValueArgument() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "v4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let elements = [element(4, role: "AXTextArea", label: "Document",
                                value: "Old body", token: "tok-4")]
        let first = try await decider.nextStep(obs(elements))
        guard case .askUser(let question, _) = first else {
            return XCTFail("expected replacement question, got \(first)")
        }
        let answer = RoundRecord(stepIndex: 0, echo: .ask, summary: question,
                                 askKind: .question, askQuestion: question, askAnswer: "Exact new body")
        let result = try await decider.nextStep(obs(elements, history: [answer]))
        guard case .act(let request) = result else {
            return XCTFail("expected answered replacement, got \(result)")
        }
        XCTAssertEqual(request.tool, "set_value")
        XCTAssertEqual(request.args["value"], .string("Exact new body"))
        XCTAssertNil(request.args["text"])
    }

    func testReplacementAcceptsExplicitEmptyLiteral() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "v4", confidence: nil, doneVote: nil)]
        let brief = TaskBrief(goal: "Clear the document", values: ["text": ""])
        let result = try await makeDecider(fake).nextStep(obs([
            element(4, role: "AXTextArea", label: "Document", value: "Old body", token: "tok-4"),
        ], task: brief))
        guard case .act(let request) = result else {
            return XCTFail("explicit empty replacement is not a missing answer: \(result)")
        }
        XCTAssertEqual(request.tool, "set_value")
        XCTAssertEqual(request.args["value"], .string(""))
    }

    func testKnownEmptyEditableValueCanProveClearButUnknownAndSecureCannot() {
        let snapshot = AXSnapshot(windowTitle: "Owned document", snapshotID: "owned-1", elements: [
            element(1, role: "AXTextArea", label: "Document", value: ""),
            element(2, role: "AXTextField", label: "Unknown", value: nil),
            element(3, role: "AXSecureTextField", label: "Password", value: ""),
            element(4, role: "AXStaticText", label: "", value: ""),
        ], treeMarkdown: "")
        let facts = ObservedGoalProof.facts(in: snapshot)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.node.index, 1)
        XCTAssertEqual(facts.first?.kind, .value)
        XCTAssertEqual(facts.first?.content, "")
    }

    func testSecureFieldDoesNotOfferReplacement() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
        _ = try await makeDecider(fake).nextStep(obs([
            element(4, role: "AXSecureTextField", label: "Password", value: "private"),
        ]))
        XCTAssertFalse(fake.candidateSets[0].contains("v4"))
    }

    func testKnownEmptyFieldKeepsInsertionWithoutEquivalentReplacement() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "reobserve", confidence: nil, doneVote: nil)]
        _ = try await makeDecider(fake).nextStep(obs([
            element(4, role: "AXTextField", label: "Name", value: ""),
        ]))
        XCTAssertTrue(fake.candidateSets[0].contains("t4"))
        XCTAssertFalse(fake.candidateSets[0].contains("v4"))
    }

    func testWindowOnlyDeciderKeepsLocalControlsButNotGlobalCapabilities() async throws {
        var offered: [String] = []
        let decider = JevDecider(choose: { _, candidates in
            offered = candidates.map(\.id)
            return .init(id: "reobserve", confidence: nil, doneVote: nil)
        }, windowOnly: true)
        _ = try await decider.nextStep(obs([
            element(1, label: "Pause"),
        ], task: TaskBrief(goal: "Pause playback and read the clipboard")))
        XCTAssertTrue(offered.contains("e1"))
        XCTAssertFalse(offered.contains { $0.hasPrefix("media:") })
        XCTAssertFalse(offered.contains("clipboard:read"))
    }

    /// A field-matched literal beats the generic "text" value — the same
    /// precedence the loop's textPayload applies.
    func testTypePickPrefersFieldMatchedValue() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        var brief = TaskBrief(goal: "fill the form")
        brief.values = ["name": "Karan", "text": "generic"]
        let result = try await decider.nextStep(obs([
            element(4, role: "AXTextField", label: "Name", token: "tok-4")],
            task: brief))
        guard case .act(let request) = result else {
            return XCTFail("expected .act, got \(result)")
        }
        XCTAssertEqual(request.args["text"], .string("Karan"))
    }

    /// No literal anywhere — the decider asks; it never writes text.
    func testTypePickWithoutLiteralAsksUser() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let result = try await decider.nextStep(obs([
            element(4, role: "AXTextField", label: "Name", token: "tok-4")]))
        guard case .askUser(let question, _) = result else {
            return XCTFail("expected .askUser, got \(result)")
        }
        XCTAssertTrue(question.contains("Name"))
    }

    /// The parked question's answer is user-supplied literal — it lands
    /// verbatim as the type payload.
    func testTypePickUsesAskedAnswer() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil),
                      .init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let els = [element(4, role: "AXTextField", label: "Name", token: "tok-4")]
        let first = try await decider.nextStep(obs(els))
        guard case .askUser(let question, _) = first else {
            return XCTFail("expected .askUser, got \(first)")
        }
        let answered = RoundRecord(stepIndex: 0, echo: .ask, summary: question,
                                   askKind: .question, askQuestion: question,
                                   askAnswer: "the literal answer")
        let second = try await decider.nextStep(obs(els, history: [answered]))
        guard case .act(let request) = second else {
            return XCTFail("expected .act, got \(second)")
        }
        XCTAssertEqual(request.args["text"], .string("the literal answer"))
    }

    /// A consent ask's "yes" is not literal text — it can never leak
    /// into a field as typed content.
    func testConsentAnswerNeverBecomesText() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let consent = RoundRecord(stepIndex: 0, echo: .ask, summary: "Delete it?",
                                  askKind: .consent, askQuestion: "Delete it?",
                                  askAnswer: "yes")
        let result = try await decider.nextStep(obs([
            element(4, role: "AXTextField", label: "Name", token: "tok-4")],
            history: [consent]))
        guard case .askUser = result else {
            return XCTFail("expected .askUser, got \(result)")
        }
    }

    /// Already asked once with no answer — an honest block, not a loop.
    func testUnansweredTextAskBlocks() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "t4", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        let unanswered = RoundRecord(stepIndex: 0, echo: .ask, summary: "What should I type?",
                                     askKind: .question, askQuestion: "What should I type?",
                                     askAnswer: nil)
        let result = try await decider.nextStep(obs([
            element(4, role: "AXTextField", label: "Name", token: "tok-4")],
            history: [unanswered]))
        guard case .blocked = result else {
            return XCTFail("expected .blocked, got \(result)")
        }
    }

    // MARK: - the chooser's own failure surfaces

    /// A thrown model call propagates — the loop classifies it as a
    /// decider failure; the decider doesn't invent a fallback pick.
    func testChooseErrorPropagates() async throws {
        let fake = FakeChoose()
        struct ChooseFailure: Error {}
        fake.error = ChooseFailure()
        let decider = makeDecider(fake)
        do {
            _ = try await decider.nextStep(obs([element(1, label: "Save")]))
            XCTFail("expected the choose error to propagate")
        } catch is ChooseFailure {}
    }

    // MARK: - contract surface

    /// Reserved candidates ride every option set — the pick stays
    /// bounded even when the AX tree offers nothing.
    func testReservedCandidatesAlwaysOffered() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "done", confidence: nil, doneVote: nil)]
        let decider = makeDecider(fake)
        _ = try await decider.nextStep(obs([]))
        let ids = fake.candidateSets.first ?? []
        XCTAssertTrue(ids.contains("done"))
        XCTAssertTrue(ids.contains("reobserve"))
        XCTAssertTrue(ids.contains("stuck"))
    }

    /// A re-picked scroll is incremental progress, not a
    /// possibly-completed step — it re-dispatches.
    func testRepickedScrollRepeatsInsteadOfPixelEscalation() async throws {
        let fake = FakeChoose()
        fake.picks = [.init(id: "scroll:down", confidence: 0.9),
                      .init(id: "scroll:down", confidence: 0.9)]
        let decider = JevDecider(choose: { state, candidates in
            fake.states.append(state)
            fake.candidateSets.append(candidates.map { $0.id })
            guard !fake.picks.isEmpty else { return nil }
            return fake.picks.removeFirst()
        })
        let task = TaskBrief(goal: "scroll down the page")
        let first = try await decider.nextStep(obs([
            element(1, role: "AXScrollArea", label: "Page A")], task: task))
        guard case .act(let firstRequest) = first else {
            return XCTFail("expected act, got \(first)")
        }
        XCTAssertEqual(firstRequest.tool, "scroll")
        let history = [RoundRecord(stepIndex: 0, echo: .act,
                                   summary: firstRequest.summary,
                                   actuated: true, settleVerified: true)]
        // A changed snapshot — the scroll's own repaint — reaches the
        // pick rather than the lag-reobserve grace round.
        let second = try await decider.nextStep(obs([
            element(1, role: "AXScrollArea", label: "Page B")],
            task: task, history: history, snapshotID: "snap-2"))
        guard case .act(let secondRequest) = second else {
            return XCTFail("expected act, got \(second)")
        }
        XCTAssertEqual(secondRequest.tool, "scroll")
    }
}

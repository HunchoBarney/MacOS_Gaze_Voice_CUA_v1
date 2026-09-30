import XCTest
@testable import JevVoice

final class CuaDialogueStateTests: XCTestCase {
    private func intent(_ instruction: String = "open the document",
                        id: UUID = UUID(), capture: UUID = UUID()) -> CuaDialogueState.Intent {
        .init(id: id,
              source: .init(captureID: capture, handoffID: UUID(), revision: 0,
                            transcriptRanges: [0..<instruction.count]),
              utterance: instruction, instruction: instruction,
              target: .init(application: "Notes", windowID: "window-1",
                            description: "the document"))
    }

    private func answerSource() -> CuaDialogueState.Source {
        .init(captureID: UUID(), handoffID: UUID(), revision: 0, transcriptRanges: [0..<1])
    }

    /// Exhaustive by design: re-adding an answer/retry case fails to compile here.
    private func relationshipName(_ relationship: CuaDialogueState.Relationship) -> String {
        switch relationship {
        case .independent: return "independent"
        case .refinement: return "refinement"
        case .continuation: return "continuation"
        case .correction: return "correction"
        }
    }

    func testIdentityAndSourceSurviveAttemptsAndQuestions() throws {
        var state = CuaDialogueState()
        let original = intent()
        try state.add(original)
        let question = CuaDialogueState.Question(intentID: original.id,
                                                 prompt: "Which document?", options: ["A", "B"],
                                                 target: original.target)
        try state.ask(question)
        XCTAssertEqual(state.entry(for: original.id)?.status, .awaitingAnswer(questionID: question.id))
        XCTAssertThrowsError(try state.begin(.init(intentID: original.id, instruction: "A")))
        let answerSource = self.answerSource()
          let answer = CuaDialogueState.Answer(questionID: question.id, intentID: original.id,
                                                revision: 0, source: answerSource, utterance: "A")
          try state.answer(answer)
          let attempt = CuaDialogueState.Attempt(intentID: original.id, instruction: "open A",
                                               target: original.target, revision: 1)
        try state.begin(attempt)
        XCTAssertEqual(state.entry(for: original.id)?.intent, original)
        XCTAssertEqual(state.entry(for: original.id)?.attempts, [attempt])
        XCTAssertEqual(state.entry(for: original.id)?.question, question)
        XCTAssertEqual(state.entry(for: original.id)?.answers, [answer])
        XCTAssertEqual(state.entry(for: original.id)?.status, .executing(attemptID: attempt.id))
    }

    func testRelationshipsDoNotImplyPrerequisites() throws {
        var state = CuaDialogueState()
        let first = intent("first")
        let refinement = intent("refine")
        let dependent = intent("dependent")
        try state.add(first)
        try state.add(refinement, relationship: .refinement(of: first.id))
        try state.add(dependent, relationship: .continuation(of: first.id),
                      prerequisite: .init(intentID: dependent.id, requiresIntentID: first.id))
        XCTAssertTrue(state.canExecute(refinement.id))
        XCTAssertFalse(state.canExecute(dependent.id))
        let attempt = CuaDialogueState.Attempt(intentID: first.id, instruction: "first")
        try state.begin(attempt)
        try state.finish(attemptID: attempt.id, intentID: first.id, outcome: .verified(evidence: "observed"))
        XCTAssertFalse(state.canExecute(dependent.id), "generic success cannot establish a required fact")
        XCTAssertThrowsError(try state.add(intent("invalid"), relationship: .correction(of: UUID())))
        let factSource = intent("fact source")
        let factDependent = intent("fact dependent")
        try state.add(factSource)
        try state.add(factDependent, prerequisite: .init(intentID: factDependent.id,
                                                         requiresIntentID: factSource.id,
                                                         requiredFact: .targetObserved))
        let factAttempt = CuaDialogueState.Attempt(intentID: factSource.id, instruction: "inspect")
        try state.begin(factAttempt)
        XCTAssertThrowsError(try state.finish(attemptID: factAttempt.id, intentID: factSource.id,
                                              outcome: .verifiedFact(.init(kind: .targetObserved,
                                                                          evidence: "readback"))))
        let mismatchedTarget = CuaDialogueState.Target(
            bundle: .init(bundleID: "com.apple.Notes", displayName: "Notes"),
            process: .init(processIdentifier: 42, bundleID: "com.apple.Notes"),
            window: .init(windowID: "window-1", title: "Notes"),
            description: "observed Notes window from another attempt",
            provenance: .observed(attemptID: UUID()))
        XCTAssertThrowsError(try state.finish(attemptID: factAttempt.id, intentID: factSource.id,
                                              outcome: .verifiedFact(.init(kind: .targetObserved,
                                                                           intentID: factSource.id,
                                                                           attemptID: factAttempt.id,
                                                                           revision: 0,
                                                                           target: mismatchedTarget,
                                                                           evidence: "readback"))))
        XCTAssertEqual(state.entry(for: factSource.id)?.verifiedFacts, [])
        XCTAssertEqual(state.entry(for: factSource.id)?.status, .executing(attemptID: factAttempt.id))
        XCTAssertFalse(state.canExecute(factDependent.id))
        let observedTarget = CuaDialogueState.Target(
            bundle: .init(bundleID: "com.apple.Notes", displayName: "Notes"),
            process: .init(processIdentifier: 42, bundleID: "com.apple.Notes"),
            window: .init(windowID: "window-1", title: "Notes"),
            description: "observed Notes window",
            provenance: .observed(attemptID: factAttempt.id))
        try state.finish(attemptID: factAttempt.id, intentID: factSource.id,
                         outcome: .verifiedFact(.init(kind: .targetObserved,
                                                      intentID: factSource.id,
                                                      attemptID: factAttempt.id,
                                                      revision: 0,
                                                      target: observedTarget,
                                                      evidence: "readback")))
        XCTAssertTrue(state.canExecute(factDependent.id))
    }

    func testUncertaintyIsNotSuccessAndRetryRequiresFreshAttempt() throws {
        var state = CuaDialogueState()
        let work = intent()
        try state.add(work)
        let first = CuaDialogueState.Attempt(intentID: work.id, instruction: work.instruction)
        try state.begin(first)
        try state.finish(attemptID: first.id, intentID: work.id,
                         outcome: .uncertain(reason: "no observed confirmation"))
        XCTAssertEqual(state.entry(for: work.id)?.status,
                       .uncertain(attemptID: first.id, reason: "no observed confirmation"))
        XCTAssertFalse(state.canExecute(work.id))
        XCTAssertThrowsError(try state.finish(attemptID: first.id, intentID: work.id,
                                              outcome: .verified(evidence: "claimed")))
        try state.retryUncertain(intentID: work.id)
        let second = CuaDialogueState.Attempt(intentID: work.id, instruction: work.instruction)
        try state.begin(second)
        XCTAssertThrowsError(try state.finish(attemptID: second.id, intentID: work.id,
                                              outcome: .verified(evidence: " ")))
        try state.finish(attemptID: second.id, intentID: work.id,
                         outcome: .verified(evidence: "observed document"))
        XCTAssertEqual(state.entry(for: work.id)?.attempts, [first, second])
    }

    func testRetentionNeverEvictsUnresolvedOrTheirPrerequisite() throws {
        var state = CuaDialogueState(resolvedHistoryLimit: 0)
        let prerequisite = intent("prerequisite")
        let waiting = intent("waiting")
        let uncertain = intent("uncertain")
        try state.add(prerequisite)
        try state.add(waiting, relationship: .continuation(of: prerequisite.id),
                      prerequisite: .init(intentID: waiting.id, requiresIntentID: prerequisite.id))
        try state.add(uncertain)
        let first = CuaDialogueState.Attempt(intentID: prerequisite.id, instruction: "first")
        try state.begin(first)
        try state.finish(attemptID: first.id, intentID: prerequisite.id,
                         outcome: .verifiedFact(.init(kind: .resultObserved,
                                                      intentID: prerequisite.id,
                                                      attemptID: first.id,
                                                      revision: 0,
                                                      evidence: "verified")))
        let second = CuaDialogueState.Attempt(intentID: uncertain.id, instruction: "second")
        try state.begin(second)
        try state.finish(attemptID: second.id, intentID: uncertain.id,
                         outcome: .uncertain(reason: "unknown"))
        XCTAssertNotNil(state.entry(for: prerequisite.id))
        XCTAssertNotNil(state.entry(for: waiting.id))
        XCTAssertNotNil(state.entry(for: uncertain.id))
        XCTAssertTrue(state.canExecute(waiting.id))
        let third = CuaDialogueState.Attempt(intentID: waiting.id, instruction: "third")
        try state.begin(third)
        try state.finish(attemptID: third.id, intentID: waiting.id,
                         outcome: .failed(reason: "not found"))
        XCTAssertNil(state.entry(for: prerequisite.id))
        XCTAssertNotNil(state.entry(for: uncertain.id))
    }

    func testInvalidTransitionsCannotFabricateCompletion() throws {
        var state = CuaDialogueState()
        let work = intent()
        try state.add(work)
        XCTAssertThrowsError(try state.add(work))
        XCTAssertThrowsError(try state.finish(attemptID: UUID(), intentID: work.id,
                                              outcome: .verified(evidence: "fake")))
        XCTAssertThrowsError(try state.answer(.init(questionID: UUID(), intentID: work.id,
                                                     revision: 0, source: work.source,
                                                     utterance: "answer")))
        XCTAssertThrowsError(try state.add(intent("self", id: UUID()),
                                           prerequisite: .init(intentID: UUID(), requiresIntentID: work.id)))
    }

    func testRevisionAnswerProvenanceAndIdentityCannotBeReused() throws {
        var state = CuaDialogueState(resolvedHistoryLimit: 0)
        let work = intent()
        try state.add(work)
        let question = CuaDialogueState.Question(intentID: work.id, prompt: "Which?")
        try state.ask(question)
        XCTAssertThrowsError(try state.answer(.init(questionID: question.id, intentID: work.id,
                                                     revision: 0, source: work.source, utterance: "same")))
        let answer = CuaDialogueState.Answer(questionID: question.id, intentID: work.id,
                                              revision: 0, source: answerSource(), utterance: "A")
        try state.answer(answer)
        XCTAssertThrowsError(try state.ask(question))
        XCTAssertThrowsError(try state.begin(.init(intentID: work.id, instruction: "stale", revision: 0)))
        let attempt = CuaDialogueState.Attempt(intentID: work.id, instruction: "A", revision: 1)
        try state.begin(attempt)
        try state.finish(attemptID: attempt.id, intentID: work.id,
                         outcome: .verified(evidence: "done"))
        XCTAssertThrowsError(try state.add(work))
        let second = intent("second")
        try state.add(second)
        XCTAssertThrowsError(try state.begin(.init(id: attempt.id, intentID: second.id,
                                                   instruction: "duplicate")))
    }

    func testCancelRevisionInvalidatesClarificationAndStaleFacts() throws {
        var state = CuaDialogueState()
        let prerequisite = intent("choose")
        let dependent = intent("dependent")
        try state.add(prerequisite)
        try state.add(dependent, prerequisite: .init(intentID: dependent.id,
                                                     requiresIntentID: prerequisite.id))
        let question = CuaDialogueState.Question(intentID: prerequisite.id, prompt: "Which?")
        try state.ask(question)
        try state.cancel(intentID: prerequisite.id)
        XCTAssertEqual(state.entry(for: prerequisite.id)?.status, .cancelled(reason: "cancelled"))
        XCTAssertThrowsError(try state.answer(.init(questionID: question.id, intentID: prerequisite.id,
                                                    revision: 0, source: answerSource(),
                                                    utterance: "A")))
        try state.revise(intentID: prerequisite.id)
        XCTAssertThrowsError(try state.ask(question))
        let attempt = CuaDialogueState.Attempt(intentID: prerequisite.id,
                                               instruction: prerequisite.instruction,
                                               revision: 2)
        try state.begin(attempt)
        XCTAssertThrowsError(try state.finish(attemptID: attempt.id, intentID: prerequisite.id,
                                              outcome: .verifiedFact(.init(kind: .resultObserved,
                                                                          intentID: prerequisite.id,
                                                                          attemptID: attempt.id,
                                                                          revision: 1,
                                                                          evidence: "stale"))))
        XCTAssertFalse(state.canExecute(dependent.id))
    }

    func testAnswerResumesOwnerEntryInPlaceWithoutNewIntent() throws {
        var state = CuaDialogueState()
        let base = intent("base")
        try state.add(base)
        let question = CuaDialogueState.Question(intentID: base.id, prompt: "Which?")
        try state.ask(question)
        XCTAssertEqual(state.questionOwner(for: question.id), base.id)
        let answer = CuaDialogueState.Answer(questionID: question.id, intentID: base.id,
                                             revision: 0, source: answerSource(), utterance: "A")
        try state.answer(answer)
        XCTAssertEqual(state.entries.count, 1, "an answer resumes the owner; it is never a new entry")
        XCTAssertEqual(state.entry(for: base.id)?.intent, base)
        XCTAssertEqual(state.entry(for: base.id)?.revision, 1)
        XCTAssertEqual(state.entry(for: base.id)?.status, .pending)
        XCTAssertEqual(state.entry(for: base.id)?.answers, [answer])
        XCTAssertEqual(state.entry(for: base.id)?.question, question,
                       "the question remains as history on the owner entry")
        XCTAssertNil(state.questionOwner(for: question.id),
                     "an answered question no longer owns new answers")
        XCTAssertThrowsError(try state.answer(answer)) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .invalidQuestion)
        }
        try state.cancel(intentID: base.id)
        XCTAssertNotNil(state.entry(for: base.id))
        XCTAssertThrowsError(try state.answer(.init(questionID: question.id, intentID: base.id,
                                                     revision: 1, source: answerSource(),
                                                     utterance: "B"))) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .invalidQuestion)
        }
        XCTAssertEqual(state.entry(for: base.id)?.answers, [answer])
        XCTAssertEqual(state.entry(for: base.id)?.status, .cancelled(reason: "cancelled"))
    }

    func testAnswerRejectsAnsweredAndRevisedQuestionsWithoutMutation() throws {
        var state = CuaDialogueState()
        let answered = intent("answered")
        try state.add(answered)
        let answeredQuestion = CuaDialogueState.Question(intentID: answered.id, prompt: "Which?")
        try state.ask(answeredQuestion)
        let first = CuaDialogueState.Answer(questionID: answeredQuestion.id, intentID: answered.id,
                                            revision: 0, source: answerSource(), utterance: "A")
        try state.answer(first)
        XCTAssertThrowsError(try state.answer(.init(questionID: answeredQuestion.id,
                                                     intentID: answered.id, revision: 1,
                                                     source: answerSource(), utterance: "B"))) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .invalidQuestion)
        }
        XCTAssertEqual(state.entry(for: answered.id)?.answers, [first])
        XCTAssertEqual(state.entry(for: answered.id)?.revision, 1)

        let revised = intent("revised")
        try state.add(revised)
        let revisedQuestion = CuaDialogueState.Question(intentID: revised.id, prompt: "Which?")
        try state.ask(revisedQuestion)
        try state.revise(intentID: revised.id)
        XCTAssertThrowsError(try state.answer(.init(questionID: revisedQuestion.id,
                                                     intentID: revised.id, revision: 0,
                                                     source: answerSource(), utterance: "A"))) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .invalidQuestion)
        }
        XCTAssertEqual(state.entry(for: revised.id)?.answers, [])
        XCTAssertEqual(state.entry(for: revised.id)?.revision, 1)
        XCTAssertEqual(state.entry(for: revised.id)?.status, .pending)
    }

    func testAddRelationshipsAreExhaustivelyNonResuming() throws {
        // Compile-time contract: relationshipName's switch breaks if a case is re-added.
        let referenced = UUID()
        let names: [String] = [
            CuaDialogueState.Relationship.independent,
            .refinement(of: referenced),
            .continuation(of: referenced),
            .correction(of: referenced)
        ].map(relationshipName)
        XCTAssertEqual(names, ["independent", "refinement", "continuation", "correction"])

        var state = CuaDialogueState()
        let base = intent("base")
        try state.add(base)
        let question = CuaDialogueState.Question(intentID: base.id, prompt: "Which?")
        try state.ask(question)
        // An utterance shaped like an answer added through add() is an ordinary new
        // intent; it never resumes the pending question or bumps the owner revision.
        let followUp = intent("the front window")
        try state.add(followUp, relationship: .continuation(of: base.id))
        XCTAssertEqual(state.entry(for: base.id)?.status, .awaitingAnswer(questionID: question.id))
        XCTAssertEqual(state.entry(for: base.id)?.revision, 0)
        XCTAssertEqual(state.entry(for: base.id)?.answers, [])
        XCTAssertEqual(state.entry(for: followUp.id)?.status, .pending)
        XCTAssertThrowsError(try state.add(intent("unknown"), relationship: .refinement(of: UUID()))) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .unknownRelatedIntent)
        }
    }

    func testReviseCannotResetExecutingAttemptWithoutOutcomeEvidence() throws {
        var state = CuaDialogueState()
        let work = intent("executing")
        try state.add(work)
        let attempt = CuaDialogueState.Attempt(intentID: work.id, instruction: work.instruction)
        try state.begin(attempt)
        XCTAssertThrowsError(try state.revise(intentID: work.id)) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .invalidTransition)
        }
        XCTAssertEqual(state.entry(for: work.id)?.status, .executing(attemptID: attempt.id))
        XCTAssertEqual(state.entry(for: work.id)?.evidence, [])
        XCTAssertThrowsError(try state.cancel(intentID: work.id)) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .invalidTransition)
        }
        try state.finish(attemptID: attempt.id, intentID: work.id,
                         outcome: .partial(evidence: "paused safely", blockedReason: "needs revision"))
        XCTAssertEqual(state.entry(for: work.id)?.evidence,
                       [.init(attemptID: attempt.id, intentID: work.id, revision: 0,
                              outcome: .partial(evidence: "paused safely", blockedReason: "needs revision"))])
        try state.revise(intentID: work.id)
        XCTAssertEqual(state.entry(for: work.id)?.revision, 1)
        XCTAssertEqual(state.entry(for: work.id)?.status, .pending)
    }

    func testPartialBlockedCancelledOutcomesAndImmutableAttemptEvidence() throws {
        var state = CuaDialogueState()
        let partial = intent("partial")
        let blocked = intent("blocked")
        try state.add(partial)
        try state.add(blocked)
        let first = CuaDialogueState.Attempt(intentID: partial.id, instruction: "partial")
        try state.begin(first)
        try state.finish(attemptID: first.id, intentID: partial.id,
                         outcome: .partial(evidence: "moved one file", blockedReason: "permission"))
        XCTAssertEqual(state.entry(for: partial.id)?.status,
                       .partial(attemptID: first.id, evidence: "moved one file", blockedReason: "permission"))
        XCTAssertEqual(state.entry(for: partial.id)?.evidence,
                       [.init(attemptID: first.id, intentID: partial.id, revision: 0,
                              outcome: .partial(evidence: "moved one file", blockedReason: "permission"))])
        let second = CuaDialogueState.Attempt(intentID: blocked.id, instruction: "blocked")
        try state.begin(second)
        try state.finish(attemptID: second.id, intentID: blocked.id,
                         outcome: .blocked(reason: "missing permission"))
        XCTAssertEqual(state.entry(for: blocked.id)?.status,
                       .blocked(attemptID: second.id, reason: "missing permission"))
    }

    func testPartialRetainsOnlyValidatedTargetPrerequisite() throws {
        var state = CuaDialogueState()
        let source = intent("inspect target")
        let targetDependent = intent("use observed target")
        let resultDependent = intent("use completed result")
        try state.add(source)
        try state.add(targetDependent, prerequisite: .init(intentID: targetDependent.id,
                                                           requiresIntentID: source.id,
                                                           requiredFact: .targetObserved))
        try state.add(resultDependent, prerequisite: .init(intentID: resultDependent.id,
                                                           requiresIntentID: source.id,
                                                           requiredFact: .resultObserved))
        let attempt = CuaDialogueState.Attempt(intentID: source.id, instruction: source.instruction)
        try state.begin(attempt)
        let observed = CuaDialogueState.Target(
            bundle: .init(bundleID: "com.apple.Notes", displayName: "Notes"),
            window: .init(windowID: "window-1", title: "Notes"),
            description: "observed Notes window",
            provenance: .observed(attemptID: attempt.id))
        let fact = CuaDialogueState.VerifiedFact(kind: .targetObserved, intentID: source.id,
                                                 attemptID: attempt.id, revision: 0,
                                                 target: observed, evidence: "window readback")
        let outcome = CuaDialogueState.Outcome.partial(evidence: "target identified",
                                                        blockedReason: "remaining operation uncertain",
                                                        verifiedFacts: [fact])
        try state.finish(attemptID: attempt.id, intentID: source.id, outcome: outcome)
        XCTAssertEqual(state.entry(for: source.id)?.status,
                       .partial(attemptID: attempt.id, evidence: "target identified",
                                blockedReason: "remaining operation uncertain"))
        XCTAssertEqual(state.entry(for: source.id)?.verifiedFacts, [fact])
        XCTAssertEqual(state.entry(for: source.id)?.evidence.last?.outcome, outcome)
        XCTAssertTrue(state.canExecute(targetDependent.id))
        XCTAssertFalse(state.canExecute(resultDependent.id), "partial does not verify remaining effects")
        XCTAssertFalse(state.canExecute(source.id), "partial is not general completion")
    }

    func testPartialRejectsUnboundAndMismatchedFactsAtomically() throws {
        var state = CuaDialogueState()
        let source = intent("inspect target")
        let dependent = intent("use observed target")
        try state.add(source)
        try state.add(dependent, prerequisite: .init(intentID: dependent.id,
                                                     requiresIntentID: source.id,
                                                     requiredFact: .targetObserved))
        let question = CuaDialogueState.Question(intentID: source.id, prompt: "Which target?")
        try state.ask(question)
        try state.answer(.init(questionID: question.id, intentID: source.id, revision: 0,
                               source: answerSource(), utterance: "Notes"))
        let attempt = CuaDialogueState.Attempt(intentID: source.id, instruction: source.instruction,
                                               revision: 1)
        try state.begin(attempt)
        let observed = CuaDialogueState.Target(
            bundle: .init(bundleID: "com.apple.Notes", displayName: "Notes"),
            window: .init(windowID: "window-1", title: "Notes"),
            description: "observed Notes window",
            provenance: .observed(attemptID: attempt.id))
        let valid = CuaDialogueState.VerifiedFact(kind: .targetObserved, intentID: source.id,
                                                  attemptID: attempt.id, revision: 1,
                                                  target: observed, evidence: "readback")
        let invalid: [CuaDialogueState.VerifiedFact] = [
            .init(kind: .targetObserved, evidence: "unbound"),
            .init(kind: .targetObserved, intentID: source.id, attemptID: UUID(),
                  revision: 1, target: observed, evidence: "other attempt"),
            .init(kind: .targetObserved, intentID: source.id, attemptID: attempt.id,
                  revision: 0, target: observed, evidence: "stale revision"),
            .init(kind: .targetObserved, intentID: source.id, attemptID: attempt.id,
                  revision: 1, target: .init(bundle: observed.bundle, window: observed.window,
                                             description: "other attempt target",
                                             provenance: .observed(attemptID: UUID())),
                  evidence: "wrong target provenance")
        ]
        for fact in invalid {
            XCTAssertThrowsError(try state.finish(attemptID: attempt.id, intentID: source.id,
                                                   outcome: .partial(evidence: "target identified",
                                                                     blockedReason: "not finished",
                                                                     verifiedFacts: [valid, fact])))
            XCTAssertEqual(state.entry(for: source.id)?.verifiedFacts, [])
            XCTAssertEqual(state.entry(for: source.id)?.evidence, [])
            XCTAssertEqual(state.entry(for: source.id)?.status, .executing(attemptID: attempt.id))
            XCTAssertFalse(state.canExecute(dependent.id))
        }
    }

    func testContextVersionAndFocusContractsAreDistinct() {
        let uiTarget = CuaDialogueState.Target(
            bundle: .init(bundleID: "com.apple.Notes", displayName: "Notes"),
            window: .init(windowID: "w", title: "Notes"),
            description: "selection",
            provenance: .source(intent().source))
        let context = CuaDialogueState.ContextVersion(semanticRevision: 3,
                                                      readSet: ["selection", "frontmostApp"])
        XCTAssertEqual(context.readSet, ["selection", "frontmostApp"])
        XCTAssertNotEqual(CuaDialogueState.FocusContract.uiSelection(target: uiTarget),
                          .conversational(intentID: UUID()))
    }

    func testTransitiveRetentionAndUnresolvedCapacity() throws {
        var state = CuaDialogueState(resolvedHistoryLimit: 0, unresolvedLimit: 2)
        let ancestor = intent("ancestor")
        let parent = intent("parent")
        let child = intent("child")
        try state.add(ancestor)
        try state.add(parent, relationship: .continuation(of: ancestor.id))
        let first = CuaDialogueState.Attempt(intentID: ancestor.id, instruction: "ancestor")
        try state.begin(first)
        try state.finish(attemptID: first.id, intentID: ancestor.id,
                         outcome: .verified(evidence: "done"))
        try state.add(child, relationship: .continuation(of: parent.id))
        XCTAssertNotNil(state.entry(for: ancestor.id))
        XCTAssertThrowsError(try state.add(intent("overflow"))) { error in
            XCTAssertEqual(error as? CuaDialogueState.TransitionError, .unresolvedCapacity)
        }
        let second = CuaDialogueState.Attempt(intentID: parent.id, instruction: "parent")
        try state.begin(second)
        try state.finish(attemptID: second.id, intentID: parent.id,
                         outcome: .verified(evidence: "done"))
        XCTAssertNotNil(state.entry(for: ancestor.id))
        XCTAssertNotNil(state.entry(for: parent.id))
    }
}

import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class VoiceAccuracyTests: XCTestCase {
    private func vocabularyContext() -> VoiceAdmissionContext {
        var value = VoiceAdmissionContext()
        value.targetID = "fixture.editor.window"
        value.targetAppID = "fixture.editor"
        value.editableTarget = true
        value.entities = [
            .init(name: "Google Chrome", id: "com.google.Chrome", canOpenLocally: true),
            .init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true),
            .init(name: "Notes", id: "com.apple.Notes", canOpenLocally: true)
        ]
        return value
    }

    func testNamedAppVocabularyUsesObservedWholeTokens() async throws {
        let phrases = [
            "show Chrome", "bring Google to the front", "bring Chrome up",
            "show the Google Chrome app", "focus my Chrome application",
            "Could you please show me Chrome?", "Please, switch back to Chrome.",
            "Can you go back to Google Chrome?", "Take me to Chrome",
            "Get Google to the front"
        ]
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context = vocabularyContext()
        for phrase in phrases {
            let decision = await session.submitTyped(phrase, now: 1)
            let admission = try XCTUnwrap(decision)
            XCTAssertEqual(admission.route, .local, phrase)
            XCTAssertEqual(admission.slots["target_id"], "com.google.Chrome", phrase)
            XCTAssertEqual(admission.text, phrase)
        }
        XCTAssertEqual(calls, phrases.count)
    }

    func testAmbiguousAndFragmentAppNamesNeverExecute() async throws {
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context = vocabularyContext()
        for phrase in ["show Go", "show Chroma", "show com.google", "show GateHub",
                       "Please, don't show Chrome", "Could you please not show Chrome",
                       "Please show Chrome actually don't"] {
            let decision = await session.submitTyped(phrase, now: 1)
            let admission = try XCTUnwrap(decision)
            XCTAssertTrue([VoiceRoute.refuse, .clarify].contains(admission.route), phrase)
        }
        session.context.entities.append(.init(name: "Google Drive", id: "fixture.drive", canOpenLocally: true))
        let ambiguousDecision = await session.submitTyped("show Google", now: 1)
        let ambiguous = try XCTUnwrap(ambiguousDecision)
        XCTAssertEqual(ambiguous.route, .clarify)
        XCTAssertEqual(calls, 0)
        let exactDecision = await session.submitTyped("show Google Chrome", now: 1)
        let exact = try XCTUnwrap(exactDecision)
        XCTAssertEqual(exact.slots["target_id"], "com.google.Chrome")
        XCTAssertEqual(calls, 1)
        session.context.entities.removeAll { $0.id == "fixture.drive" }
        session.context.entities.append(session.context.entities[0])
        let duplicateDecision = await session.submitTyped("show Chrome", now: 1)
        XCTAssertEqual(duplicateDecision?.route, .local, "duplicate observations of one identity are not two apps")
        XCTAssertEqual(calls, 2)
        session.context.entities = [
            .init(name: "Email Mail", id: "fixture.email.mail", canOpenLocally: true),
            .init(name: "Email Calendar", id: "fixture.email.calendar", canOpenLocally: true)
        ]
        let nicknameAmbiguity = await session.submitTyped("show email", now: 1)
        XCTAssertEqual(nicknameAmbiguity?.route, .clarify)
        XCTAssertEqual(calls, 2)
    }

    func testOriginalAppFrameWinsOverConvenienceWording() async throws {
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context = vocabularyContext()
        session.context.entities.append(.init(name: "Me Chrome", id: "fixture.me", canOpenLocally: true))
        let originalDecision = await session.submitTyped("show me Chrome", now: 1)
        let original = try XCTUnwrap(originalDecision)
        XCTAssertEqual(original.slots["target_id"], "fixture.me")
        session.context.entities.removeAll { $0.id == "fixture.me" }
        session.context.entities += [
            .init(name: "Me Chrome One", id: "fixture.me.one", canOpenLocally: true),
            .init(name: "Me Chrome Two", id: "fixture.me.two", canOpenLocally: true)
        ]
        let ambiguousDecision = await session.submitTyped("show me Chrome", now: 1)
        let ambiguous = try XCTUnwrap(ambiguousDecision)
        XCTAssertEqual(ambiguous.route, .clarify)
        XCTAssertEqual(calls, 1)
    }

    func testCourtesyPreservesLiteralAndCapturedReplyData() async throws {
        let session = LocalSpeechSession { _ in }
        session.context = vocabularyContext()
        let literal = #"Could you please type "Don't open Chrome!""#
        let typedDecision = await session.submitTyped(literal, now: 1)
        let typed = try XCTUnwrap(typedDecision)
        XCTAssertEqual(typed.route, .local)
        XCTAssertEqual(typed.slots["text"], "Don't open Chrome!")
        XCTAssertEqual(typed.text, literal)
        let task = UUID(), askID = UUID()
        let option = "Please show me Chrome"
        let ask = VoiceAdmissionContext.Ask(taskID: task, askID: askID, kind: .choice, options: [option])
        session.context.capturedAsks = [ask]
        session.context.currentAsks = [ask]
        session.context.tasks = [task]
        let replyDecision = await session.submitTyped(option, now: 1)
        let reply = try XCTUnwrap(replyDecision)
        XCTAssertEqual(reply.intent, "respond")
        XCTAssertEqual(reply.slots["ask_id"], askID.uuidString)
        XCTAssertEqual(reply.text, option)
        let otherAsk = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice, options: [option])
        session.context.capturedAsks.append(otherAsk)
        session.context.currentAsks.append(otherAsk)
        let ambiguousDecision = await session.submitTyped(option, now: 1)
        XCTAssertEqual(ambiguousDecision?.route, .clarify)
        let question = VoiceAdmissionContext.Ask(taskID: task, askID: askID, kind: .question)
        session.context.capturedAsks = [question]; session.context.currentAsks = [question]
        let freeform = "Please, follow up tomorrow"
        let answerDecision = await session.submitTyped(freeform, now: 1)
        XCTAssertEqual(answerDecision?.intent, "respond")
        XCTAssertEqual(answerDecision?.text, freeform)
        let unsure = await session.submitTyped("Not sure", now: 1)
        XCTAssertEqual(unsure?.intent, "respond")
    }

    func testExplicitFocusInflectionUsesUniqueObservedIdentity() async throws {
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context = vocabularyContext()
        session.context.entities.append(.init(name: "Archive", id: "fixture.archive", canOpenLocally: true))
        for (phrase, expected) in [
            ("Switch to calculators.", "com.apple.calculator"),
            ("bring calculators to front", "com.apple.calculator"),
            ("switch to archives", "fixture.archive"),
            ("bring archives to the front", "fixture.archive")
        ] {
            let decision = await session.submitTyped(phrase, now: 1)
            let admission = try XCTUnwrap(decision)
            XCTAssertEqual(admission.route, .local, phrase)
            XCTAssertEqual(admission.slots["target_id"], expected, phrase)
            XCTAssertEqual(admission.text, phrase)
            let command = VoiceAdmissionPolicy.commandText(phrase, context: session.context)
            let query = try XCTUnwrap(FastAction.parseOpen(command)?.query)
            let apps = session.context.entities.map { entity in JSONValue.object([
                "name": .string(entity.name), "bundle_id": .string(entity.id)
            ]) }
            XCTAssertEqual(FastAction.resolveOpenApp(query: query, apps: apps, frontmostBundle: nil)?.bundle,
                           expected, phrase)
        }
        XCTAssertEqual(calls, 4)
    }

    func testFocusInflectionDoesNotExpandUnknownsOrLiteralData() async throws {
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context = vocabularyContext()
        for phrase in ["calculators", "open calculators", "show calculators",
                       "switch to calender", "switch to Calcultaor", "switch to Chroma",
                       "switch to calculatorss", "switch to calc", "don't switch to calculators",
                       "never bring calculators to front", "switch to calculators and Notes",
                       "switch to calculators or Notes"] {
            let decision = await session.submitTyped(phrase, now: 1)
            let admission = try XCTUnwrap(decision)
            XCTAssertNotEqual(admission.route, .local, phrase)
        }
        XCTAssertEqual(calls, 0)
        let literal = #"type "switch to calculators""#
        let literalDecision = await session.submitTyped(literal, now: 1)
        let admission = try XCTUnwrap(literalDecision)
        XCTAssertEqual(admission.slots["text"], "switch to calculators")
        XCTAssertEqual(admission.text, literal)
        XCTAssertEqual(calls, 1)
    }

    func testFocusInflectionPreservesExactPluralAndAmbiguousObservations() async throws {
        let session = LocalSpeechSession { _ in }
        session.context = vocabularyContext()
        session.context.entities.append(.init(name: "Calculators", id: "fixture.plural", canOpenLocally: true))
        let exactDecision = await session.submitTyped("switch to calculators", now: 1)
        let exact = try XCTUnwrap(exactDecision)
        XCTAssertEqual(exact.slots["target_id"], "fixture.plural")
        session.context.entities.removeAll { $0.id == "fixture.plural" }
        session.context.entities.append(.init(name: "Calculator", id: "fixture.other", canOpenLocally: true))
        let ambiguousDecision = await session.submitTyped("switch to calculators", now: 1)
        let ambiguous = try XCTUnwrap(ambiguousDecision)
        XCTAssertEqual(ambiguous.route, .clarify)
        session.context.entities.removeAll { $0.id == "fixture.other" }
        session.context.entities.append(.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: false))
        let unavailableDecision = await session.submitTyped("switch to calculators", now: 1)
        let unavailable = try XCTUnwrap(unavailableDecision)
        XCTAssertNotEqual(unavailable.route, .local)
        session.context.entities = []
        let absentDecision = await session.submitTyped("switch to calculators", now: 1)
        let absent = try XCTUnwrap(absentDecision)
        XCTAssertEqual(absent.route, .clarify)
    }

    func testFocusInflectionRetainsDisplayScopeInsteadOfDroppingIt() async throws {
        let session = LocalSpeechSession { _ in XCTFail("scoped inflection must not dispatch locally") }
        session.context = vocabularyContext()
        for phrase in ["switch to calculators on this monitor",
                       "bring calculators to front on this monitor",
                       "switch to calculators on monitor 2"] {
            let decision = await session.submitTyped(phrase, now: 1)
            let admission = try XCTUnwrap(decision)
            XCTAssertNotEqual(admission.route, .local, phrase)
            XCTAssertEqual(VoiceAdmissionPolicy.commandText(phrase, context: session.context), phrase)
        }
    }

    func testFocusInflectionDoesNotResolveDuringCapturedOrCurrentAsks() async throws {
        let session = LocalSpeechSession { _ in XCTFail("inflection must not bypass a pending ask") }
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(),
                                            kind: .choice, options: ["one", "two"])
        for captured in [true, false] {
            session.context = vocabularyContext()
            if captured { session.context.capturedAsks = [ask] }
            else { session.context.currentAsks = [ask] }
            let decision = await session.submitTyped("switch to calculators", now: 1)
            XCTAssertNotEqual(decision?.route, .local)
        }
    }

    func testFocusInflectionDeduplicatesObservedIdentityWithoutWeakWordMatching() async throws {
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context = vocabularyContext()
        session.context.entities.append(.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true))
        let decision = await session.submitTyped("switch to calculators", now: 1)
        XCTAssertEqual(decision?.route, .local)
        XCTAssertEqual(decision?.slots["target_id"], "com.apple.calculator")
        XCTAssertEqual(calls, 1)
        session.context.entities = [
            .init(name: "Color Calculator", id: "fixture.color", canOpenLocally: true),
            .init(name: "Calculator Pro", id: "fixture.pro", canOpenLocally: true)
        ]
        let ambiguousDecision = await session.submitTyped("switch to calculators", now: 1)
        XCTAssertEqual(ambiguousDecision?.route, .clarify)
        let exactAmbiguousDecision = await session.submitTyped("switch to calculator", now: 1)
        XCTAssertEqual(exactAmbiguousDecision?.route, .clarify)
        XCTAssertEqual(calls, 1)
    }

    func testCommandShapedChoiceIsReplyNotTyping() async throws {
        var admissions: [VoiceAdmission] = []
        let session = LocalSpeechSession { admissions.append($0) }
        session.context = vocabularyContext()
        let task = UUID(), askID = UUID()
        let choice = VoiceAdmissionContext.Ask(taskID: task, askID: askID,
                                             kind: .choice, options: ["type Hello"])
        session.context.capturedAsks = [choice]; session.context.currentAsks = [choice]
        let reply = await session.submitTyped("type Hello", now: 1)
        XCTAssertEqual(reply?.intent, "respond")
        XCTAssertEqual(reply?.slots["ask_id"], askID.uuidString)
        XCTAssertEqual(reply?.text, "type Hello")
        session.context.currentAsks = []
        let stale = await session.submitTyped("type Hello", now: 1)
        XCTAssertEqual(stale?.route, .refuse)
        XCTAssertEqual(stale?.reason, "ask_changed")
        let second = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(),
                                             kind: .choice, options: ["type Hello"])
        session.context.capturedAsks = [choice, second]; session.context.currentAsks = [choice, second]
        let ambiguous = await session.submitTyped("type Hello", now: 1)
        XCTAssertEqual(ambiguous?.route, .clarify)
        XCTAssertEqual(admissions.count, 1)
        XCTAssertFalse(admissions.contains { $0.intent == "type" })
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func manifest() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/P3/manifest.json")))
    }

    private func context(_ name: String, document: JSONValue) throws -> VoiceAdmissionContext {
        let value = try XCTUnwrap(document["contexts"]?[name])
        var context = VoiceAdmissionContext()
        context.targetID = value["target_id"]?.string
        context.editableTarget = value["editable_target"]?.bool ?? false
        context.entities = (value["entities"]?.array ?? []).compactMap {
            guard let name = $0["name"]?.string, let id = $0["id"]?.string else { return nil }
            return VoiceAdmissionContext.Entity(name: name, id: id, canOpenLocally: $0["can_open_locally"]?.bool ?? false)
        }
        func ask(_ value: JSONValue) -> VoiceAdmissionContext.Ask? {
            guard let t = value["task_id"]?.string.flatMap(UUID.init(uuidString:)),
                  let a = value["ask_id"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
            return VoiceAdmissionContext.Ask(taskID: t, askID: a)
        }
        let asks = (value["asks"]?.array ?? []).compactMap(ask)
        context.capturedAsks = value["captured_ask"].flatMap(ask).map { [$0] } ?? asks
        context.currentAsks = value["current_ask"].flatMap(ask).map { [$0] } ?? asks
        context.selectedTask = value["selected_task"]?.string.flatMap(UUID.init(uuidString:))
        context.tasks = Set((value["tasks"]?.array ?? []).compactMap { $0["task_id"]?.string.flatMap(UUID.init(uuidString:)) })
        return context
    }

    func testFrozenCasesInvokeTheProductionSessionExecutor() async throws {
        let doc = try manifest()
        let groups = ["clear", "negative", "boundary"]
        XCTAssertEqual(doc["clear"]?.array?.count, 50)
        XCTAssertEqual(doc["negative"]?.array?.count, 14)
        XCTAssertEqual(doc["boundary"]?.array?.count, 4)
        for group in groups {
            for row in try XCTUnwrap(doc[group]?.array) {
                let id = try XCTUnwrap(row["id"]?.string)
                let text = try XCTUnwrap(row["utterance"]?.string)
                let contextID = row["context"]?.string ?? "owned-browser-window"
                var actualExecutions: [VoiceAdmission] = []
                let session = LocalSpeechSession { actualExecutions.append($0) }
                session.context = try context(contextID, document: doc)
                let decision = await session.submitTyped(text, now: 1)
                let result = try XCTUnwrap(decision, id)
                let expectedRoute = row["route"]?.string ?? (group == "clear" ? "local" : "")
                let expectedCount = row["dispatch_count"]?.integer ?? (group == "clear" ? 1 : 0)
                XCTAssertEqual(result.route.rawValue, expectedRoute, id)
                XCTAssertEqual(actualExecutions.count, expectedCount, id)
                if let reason = row["reason"]?.string { XCTAssertEqual(result.reason, reason, id) }
                if group == "clear" || group == "boundary" {
                    let intent = row["intent"]?.string ?? doc["clear_rules"]?["intent"]?.string
                    if let intent { XCTAssertEqual(result.intent, intent, id) }
                    if let keys = row["keys"]?.array?.compactMap(\.string) {
                        XCTAssertEqual(result.slots["keys"], keys.joined(separator: "+"), id)
                    }
                    for (key, value) in row["slots"]?.object ?? [:] {
                        let expected = value.string ?? value.integer.map(String.init)
                        XCTAssertEqual(result.slots[key]?.lowercased(), expected?.lowercased(), "\(id):\(key)")
                    }
                }
            }
        }
    }

    func testCapturedTargetCannotBeReplacedDuringHold() async {
        var executions = 0
        let session = LocalSpeechSession { _ in executions += 1 }
        session.context.targetID = "first-window"
        let turn = session.begin(mode: .typed, ready: true, now: 0)
        session.context.targetID = "different-window"
        XCTAssertTrue(session.release(turn, now: 1))
        let decision = await session.finalize("scroll down", turn: turn, drainedFrames: 0, now: 1.1)
        XCTAssertEqual(decision?.route, .clarify)
        XCTAssertEqual(decision?.reason, "target_changed")
        XCTAssertEqual(executions, 0)
    }

    func testQuoteDoesNotTurnIntoCancellation() {
        var c = VoiceAdmissionContext()
        c.targetID = "fixture"; c.editableTarget = true
        let proposal = VoiceAdmissionPolicy.propose("type the word stop", context: c)
        XCTAssertEqual(proposal.intent, "type")
        XCTAssertEqual(proposal.slots["text"], "stop")
        XCTAssertEqual(VoiceAdmissionPolicy.propose("do not cancel", context: c).route, .refuse)
    }

    func testUtterancePunctuationDropsOnlyForUnquotedSpeech() {
        var c = VoiceAdmissionContext()
        c.targetID = "fixture"; c.editableTarget = true
        // h13: ASR's utterance-final period is prosody, not spoken payload.
        let spoken = VoiceAdmissionPolicy.propose("Type the word stop.", context: c, speech: true)
        XCTAssertEqual(spoken.slots["text"], "stop")
        // A typed command has no ASR prosody: its punctuation stays.
        let typed = VoiceAdmissionPolicy.propose("type hello!", context: c)
        XCTAssertEqual(typed.slots["text"], "hello!")
        // Explicitly quoted literals stay verbatim even for speech.
        let quoted = VoiceAdmissionPolicy.propose("type \"stop.\"", context: c, speech: true)
        XCTAssertEqual(quoted.slots["text"], "stop.")
        // Interior punctuation is never touched.
        let interior = VoiceAdmissionPolicy.propose("type don't, please.", context: c, speech: true)
        XCTAssertEqual(interior.slots["text"], "don't, please")
    }
}

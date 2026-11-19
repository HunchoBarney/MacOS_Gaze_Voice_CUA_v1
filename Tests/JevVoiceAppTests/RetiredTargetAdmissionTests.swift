import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class RetiredTargetAdmissionTests: XCTestCase {
    func testExternalFinalRequiresOneUnchangedChoiceOrAsksForTheControl() async throws {
        let choice = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice,
                                               options: ["Save", "Discard"])
        let other = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice, options: choice.options)
        let reordered = VoiceAdmissionContext.Ask(taskID: choice.taskID, askID: choice.askID,
                                                  kind: .choice, options: ["Discard", "Save"])
        let quoted = VoiceAdmissionContext.Ask(taskID: choice.taskID, askID: choice.askID,
                                               kind: .choice, options: ["“Click two”", "Other"])
        typealias Row = (String, [VoiceAdmissionContext.Ask], [VoiceAdmissionContext.Ask], Bool)
        let qualifiedClick: Row = ("Click in Notes.", [], [], false)
        let cases: [Row] = [
            ("Type hello there here.", [], [], false), ("Please minimize this.", [], [], false),
            ("Close it.", [], [], false), ("Hide this.", [], [], false),
            ("Close on this monitor.", [], [], false), ("Click on this monitor.", [], [], false),
            ("Type hello on this monitor.", [], [], false), ("Click in MissingFixtureApp.", [], [], false),
            qualifiedClick,
            ("Show numbers.", [], [], false), ("Please hide the numbers.", [], [], false),
            ("Show numbers everywhere.", [], [], false), ("Show numbers on this screen?", [], [], false), ("Click two.", [], [], false),
            ("Click two.", [choice], [choice], true), ("Click three.", [choice], [choice], false),
            ("Click two.", [choice], [], false), ("Click two.", [choice], [other], false),
            ("Click two.", [choice], [choice, other], false), ("Click two.", [choice], [reordered], false),
            ("Click two in Safari.", [choice], [choice], false), ("Pick two.", [choice], [choice], false),
            ("Choose two.", [choice], [choice], false), ("“Click two”", [quoted], [quoted], true)
        ]
        for (row, hasTarget) in cases.map({ ($0, true) }) + [(qualifiedClick, false)] {
            let (text, captured, current, answers) = row
            let session = ConversationSession()
            defer { session.stop() }
            var context = VoiceAdmissionContext()
            if hasTarget {
                context.targetID = "window:42"; context.targetAppID = "fixture.editor"; context.windowID = 42
                context.editableTarget = true
            }
            context.entities = [.init(name: "Numbers", id: "fixture.numbers", canOpenLocally: true),
                                .init(name: "Notes", id: "fixture.notes", canOpenLocally: true)]
            context.capturedAsks = captured; context.currentAsks = captured
            context.selectedTask = captured.count == 1 ? captured.first?.taskID : nil
            session.readContext = { context }
            session.makeSpeechSession = { snapshot in
                let owner = LocalSpeechSession { _ in XCTFail("Unexpected automatic effect") }
                owner.context = snapshot
                return owner
            }
            session.interpret = { _, _, _ in XCTFail("Unexpected interpreter"); return .init(kind: .ignore) }
            session.controlQuestion = { _, _, _, _ in XCTFail("Unexpected screen inquiry") }
            session.spokenGazeClick = { _, _, _ in XCTFail("Unexpected gaze click"); return false }
            let lateReplacement = text == "Pick two." || text == "Choose two."
            if lateReplacement { session.beforeAction = { context.currentAsks = text == "Pick two." ? [reordered] : [choice, other] } }
            session.remote = { _, _, _ in XCTFail("Unexpected provider") }
            session.onControl = { _ in XCTFail("Unexpected control") }
            let settled = expectation(description: text)
            var executions = 0
            session.execute = { command in
                executions += 1
                XCTAssertTrue(answers)
                XCTAssertEqual(command.decision.kind, .answer)
                XCTAssertEqual(command.admission.slots["task_id"], choice.taskID.uuidString)
                XCTAssertEqual(command.admission.slots["ask_id"], choice.askID.uuidString)
                return .init(verified: true, waitingForAnswer: false, message: "Answered.")
            }
            session.onEvent = { event in
                if case .feedback(_, let message) = event {
                    if lateReplacement { XCTAssertTrue(message.contains("question changed")) }
                    else if !answers { XCTAssertEqual(message, "Please name the control you want to use.") }
                    settled.fulfill()
                }
            }
            try session.startExternal(session: UUID())
            let item = try session.beginExternal(input: .init(connectionID: UUID(), itemID: "fixture"), at: 0)
            XCTAssertTrue(session.commitExternal(item, at: 1))
            context.currentAsks = current
            await session.finishExternal(item, text: text, at: 2)
            await fulfillment(of: [settled], timeout: 2)
            await session.finishExternal(item, text: text, at: 3)
            XCTAssertEqual(executions, answers ? 1 : 0)
        }
    }

    func testSubmittedAndDictatedWordsKeepSeparateAuthority() async throws {
        let owner = LocalSpeechSession { _ in XCTFail("A retired target isn't an action") }
        var context = VoiceAdmissionContext()
        context.targetID = "field"; context.editableTarget = true
        context.entities = [.init(name: "Numbers", id: "fixture.numbers", canOpenLocally: true)]
        owner.context = context
        for phrase in ["Numbers", "Show me the numbers", "click two", "type hello there here",
                       "close this window", "hide this", "minimize it", "close on this monitor"] {
            let result = await owner.submitTyped(phrase, now: 0)
            XCTAssertEqual(result?.reason, "unbound_pointing")
            XCTAssertEqual(result?.route, .clarify)
        }
        let input = VoiceRealtimeInput(connectionID: UUID(), itemID: "dictation")
        let turn = owner.beginRemoteCapture(id: UUID(), mode: .dictation, connection: input.connectionID, now: 0)
        XCTAssertTrue(owner.commitRemoteCapture(turn, input: input, now: 1))
        let result = await owner.finishRemoteCapture("Click two.", turn: turn, input: input, now: 2)
        XCTAssertEqual(result?.route, .dictation)
        XCTAssertEqual(result?.text, "Click two.")
    }

    func testUnboundGazeWordsCanAnswerOnlyTheirExactChoiceLabel() {
        var context = VoiceAdmissionContext()
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice,
                                             options: ["Close it", "Not now"])
        context.capturedAsks = [ask]; context.currentAsks = [ask]
        XCTAssertEqual(VoiceAdmissionPolicy.propose("Close it", context: context, speech: true).intent, "respond")
        XCTAssertEqual(VoiceAdmissionPolicy.propose("Hide this", context: context, speech: true).route, .clarify)
        context.currentAsks = []
        XCTAssertEqual(VoiceAdmissionPolicy.propose("Close it", context: context, speech: true).route, .clarify)
    }

    func testQuotedDisplayTextReachesTheTaskAsLiteralData() async throws {
        let session = ConversationSession()
        defer { session.stop() }
        let final = #"Type "hello on this monitor""#
        let field = LiteralFixtureField()
        field.bind(session, app: "fixture.editor", window: 42)
        var context = VoiceAdmissionContext()
        context.targetID = "window:42"; context.targetAppID = "fixture.editor"; context.windowID = 42
        context.editableTarget = true
        session.readContext = { context }
        session.makeSpeechSession = { snapshot in
            let owner = LocalSpeechSession { _ in XCTFail("Unexpected automatic effect") }
            owner.context = snapshot
            owner.onDecision = { admission in
                XCTAssertEqual(admission.text, final)
                XCTAssertEqual(admission.intent, "type")
                XCTAssertEqual(admission.slots["text"], "hello on this monitor")
                XCTAssertNil(FastAction.retiredTargetRequest(admission.text))
            }
            return owner
        }
        session.interpret = { _, _, _ in XCTFail("Literal needed an interpreter"); throw CancellationError() }
        session.onControl = { _ in XCTFail("Unexpected control") }
        session.remote = { _, _, _ in XCTFail("Unexpected remote turn") }
        session.spokenGazeClick = { _, _, _ in XCTFail("Unexpected gaze click"); return false }
        let executed = expectation(description: "captured literal task")
        session.execute = { _ in XCTFail("Literal entered a generic task"); throw CancellationError() }
        session.onEvent = { event in
            if case .feedback(_, let message) = event {
                XCTAssertEqual(message, "Typed the text.")
                XCTAssertEqual(field.writes, 1)
                XCTAssertEqual(field.value, "hello on this monitor")
                executed.fulfill()
            }
        }
        try session.startExternal(session: UUID())
        let item = try session.beginExternal(input: .init(connectionID: UUID(), itemID: "literal"), at: 0)
        XCTAssertTrue(session.commitExternal(item, at: 1))
        await session.finishExternal(item, text: final, at: 2)
        await fulfillment(of: [executed], timeout: 2)
    }
}

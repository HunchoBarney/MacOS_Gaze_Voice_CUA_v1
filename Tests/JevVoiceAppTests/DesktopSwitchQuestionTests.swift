import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class DesktopSwitchQuestionTests: XCTestCase {
    func testExactSpokenQuestionHasOnlyLocalStatusAuthority() {
        var context = VoiceAdmissionContext()
        for words in ["Did it switch?", "did it switch", "  DID   it\nswitch. ", "Did it switch !"] {
            let proposal = VoiceAdmissionPolicy.propose(words, context: context, speech: true)
            XCTAssertEqual(proposal.route, .local)
            XCTAssertEqual(proposal.intent, "desktop_switch_status")
            XCTAssertTrue(proposal.slots.isEmpty && proposal.targetIDs.isEmpty)
            XCTAssertNil(proposal.replyTo)
        }
        let choice = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice,
                                              options: ["Did it switch?", "Next"])
        context.selectedTask = choice.taskID
        context.capturedAsks = [choice]
        context.currentAsks = [choice, .init(taskID: UUID(), askID: UUID(), kind: .question)]
        XCTAssertNil(VoiceAdmissionPolicy.propose("Did it switch?", context: context, speech: true).replyTo)
        XCTAssertNotEqual(VoiceAdmissionPolicy.propose("Did it switch?", context: .init()).intent, "desktop_switch_status")
        for words in ["“Did it switch?”", "Did it switch? Then go back.", "Did it switch desktops?",
                      "Type did it switch?", "Switch it.", "Did it switch??", "Did it not switch?"] {
            XCTAssertNotEqual(VoiceAdmissionPolicy.propose(words, context: .init(), speech: true).intent, "desktop_switch_status")
        }
    }

    private enum Scenario: CaseIterable {
        case receipt, unknown, missingOwner, cancelled, protectedCard, ambiguousAsk, askAppears, interleaved, fragment, dictation
        case singleChoice, parkedUnknown, parkedCancelled, parkedProtected, replacedAtFinal, replacedAtCard, duplicatePark
    }

    func testParkedSnapshotsIgnoreRosterOrderButNotIdentityKindOptionsOrDuplicates() {
        typealias Ask = VoiceAdmissionContext.Ask
        let a = Ask(taskID: UUID(), askID: UUID(), kind: .choice, options: ["Did it switch?", "Back"])
        let b = Ask(taskID: UUID(), askID: UUID(), kind: .question)
        XCTAssertTrue(Ask.sameParkedSnapshot([a, b], [b, a]))
        for changed in [Ask(taskID: UUID(), askID: a.askID, kind: a.kind, options: a.options),
                        Ask(taskID: a.taskID, askID: UUID(), kind: a.kind, options: a.options),
                        Ask(taskID: a.taskID, askID: a.askID, kind: .confirm, options: a.options),
                        Ask(taskID: a.taskID, askID: a.askID, kind: a.kind, options: ["Back", "Did it switch?"])] {
            XCTAssertFalse(Ask.sameParkedSnapshot([a, b], [changed, b]))
        }
        for repeated in [a, Ask(taskID: a.taskID, askID: UUID()), Ask(taskID: UUID(), askID: a.askID)] {
            XCTAssertFalse(Ask.sameParkedSnapshot([a, repeated], [a, repeated]))
        }
        XCTAssertFalse(Ask.sameParkedSnapshot([a, b], [a, a]))
        XCTAssertFalse(Ask.sameParkedSnapshot([a], []))
    }

    func testCommittedManualAndHandsFreeQuestionsOnlySettleTheOwnedCard() async throws {
        for manual in [true, false] {
            for scenario in Scenario.allCases {
                if manual && [.askAppears, .interleaved, .fragment, .replacedAtFinal].contains(scenario) { continue }
                if !manual && scenario == .dictation { continue }
                try await exercise(manual: manual, scenario: scenario)
            }
        }
    }

    private func exercise(manual: Bool, scenario: Scenario) async throws {
        let wire = RecordedVoiceWire(), client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
        defer { if manual { lane.cancel() } else { lane.stopConversation() }; client.teardown() }
        let text = "Did it switch?"
        let uncertain = "Requested Desktop 2. Switch unverified."
        let unknown = DesktopSwitchAnswers.unknown
        let choice = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice, options: [text, "Back"])
        var context = VoiceAdmissionContext(targetAppID: "fixture.editor", windowID: 42, desktopDisplayID: 77)
        let other = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .question)
        let parked: [Scenario] = [.singleChoice, .ambiguousAsk, .parkedUnknown, .parkedCancelled, .parkedProtected,
                                  .replacedAtFinal, .replacedAtCard, .duplicatePark]
        if parked.contains(scenario) {
            context.capturedAsks = scenario == .ambiguousAsk ? [choice, other] : (scenario == .duplicatePark ? [choice, choice] : [choice])
            context.currentAsks = Array(context.capturedAsks.reversed())
            context.selectedTask = choice.taskID
        }
        var turns: [UUID] = [], finals: [String] = [], withdrawals: [UUID] = [], reads: [UUID] = [], cards: [String] = []
        var parkedCards: [String] = [], deliberateAnswers: [UUID] = []
        var waiting = false
        lane.conversation.readContext = { context }
        lane.conversation.readPendingAsks = { context.currentAsks }
        lane.conversation.onEvent = { event in
            switch event {
            case .began(let id, _): turns.append(id)
            case .final(_, let words): finals.append(words)
            case .ignored(let id): withdrawals.append(id)
            case .waiting: waiting = true
            case .feedback: XCTFail("Unexpected spoken feedback")
            default: break
            }
        }
        lane.conversation.interpret = { _, _, _ in XCTFail("Unexpected interpretation"); return .init(kind: .task) }
        lane.conversation.execute = { command in
            guard scenario == .singleChoice, command.text == "One.", command.decision.kind == .answer,
                  command.admission.replyTo == .init(taskID: choice.taskID, askID: choice.askID),
                  context.currentAsks == [choice] else { XCTFail("Unexpected task or answer"); throw CancellationError() }
            deliberateAnswers.append(choice.askID)
            context.currentAsks = []; context.capturedAsks = []
            return .init(verified: true, waitingForAnswer: false, message: "")
        }
        lane.conversation.onControl = { _ in XCTFail("Unexpected control") }
        lane.exactTaskResponseHandler = { _, _, _, _ in XCTFail("Unexpected ask response"); return "{}" }
        lane.commandHandler = { _, _, _, _, _, _ in XCTFail("Unexpected task"); return "{}" }
        lane.contextProvider = { XCTFail("Unexpected context note"); return "" }
        lane.screenShotProvider = { XCTFail("Unexpected screen capture"); return nil }
        lane.workerStatus = { _ in XCTFail("Unexpected worker probe"); return .unknown }
        lane.semanticEnabled = { XCTFail("Unexpected semantic path"); return false }
        lane.onEvent = { _, event in
            if case .final(let words) = event { finals.append(words) }
            if case .toolSay = event { XCTFail("Unexpected speech") }
        }
        lane.desktopSwitchAnswer = { id, display in
            XCTAssertEqual(id, turns.last)
            XCTAssertEqual(display, 77)
            reads.append(id)
            if scenario == .cancelled || scenario == .parkedCancelled { lane.cancel() }
            if scenario == .replacedAtCard { context.currentAsks = [other] }
            if scenario == .missingOwner { return nil }
            return [.unknown, .parkedUnknown].contains(scenario) ? unknown : uncertain
        }
        lane.onLocalStatusCard = { id, message in
            XCTAssertFalse(parked.contains(scenario), "Ordinary status must not replace a parked ask")
            XCTAssertEqual(id, turns.last)
            if scenario == .protectedCard { return false }
            cards.append(message)
            return true
        }
        lane.onParkedDesktopStatus = { id, message, opened in
            XCTAssertEqual(id, turns.last)
            XCTAssertTrue([.singleChoice, .ambiguousAsk, .parkedUnknown, .parkedProtected].contains(scenario))
            XCTAssertTrue(VoiceAdmissionContext.Ask.sameParkedSnapshot(opened, context.currentAsks))
            if scenario == .parkedProtected { return false }
            parkedCards.append(message)
            return true
        }
        lane.onLocalStatusWithdrawn = { withdrawals.append($0) }
        try await lane.prepareRealtimeTransport(manual ? .manual : .conversation)
        func push(_ kind: String, item: String, words: String? = nil) async throws {
            var fields: [String: JSONValue] = ["type": .string(kind), "item_id": .string(item)]
            if let words { fields["transcript"] = .string(words) }
            try await wire.push(fields)
        }
        func capture(_ item: String) async throws {
            for kind in ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed"] {
                try await push(kind, item: item)
            }
        }
        let final = "conversation.item.input_audio_transcription.completed"
        let item: String
        var task: Task<Void, Error>?
        if manual {
            item = await wire.audioItemID()
            let id = UUID()
            turns.append(id)
            let turn = try lane.beginRemoteManualInput(id: id, mode: scenario == .dictation ? .dictation : .command,
                                                       context: context, at: 0)
            task = Task {
                let result = try await lane.finalizeRemoteManualInput(turn)
                let admission = try XCTUnwrap(result)
                XCTAssertEqual(admission.text, text)
                XCTAssertEqual(admission.realtimeInput?.itemID, item)
                await lane.completeRemoteManualAdmission(admission)
                await lane.completeRemoteManualAdmission(admission)
            }
            try await until { await wire.frames().contains { $0["type"]?.string == "input_audio_buffer.commit" } }
        } else {
            item = "fixture-item"
            try lane.beginRealtimeConversation(session: UUID())
            if scenario == .fragment {
                try await capture("fragment")
                try await push(final, item: "fragment", words: "Don't")
                try await until { waiting }
            }
            try await capture(item)
            try await until { turns.count == (scenario == .fragment ? 2 : 1) }
            if scenario == .askAppears { context.currentAsks = [choice] }
            if scenario == .replacedAtFinal { context.currentAsks = [other] }
            if scenario == .interleaved {
                try await capture("newer")
                try await until { turns.count == 2 }
            }
        }
        try await push(final, item: "wrong-item", words: text)
        try await push(final, item: item, words: text)
        try await push(final, item: item, words: text)
        if scenario == .interleaved { try await push(final, item: "newer", words: text) }
        try await task?.value
        if !manual {
            try await until {
                !cards.isEmpty || !parkedCards.isEmpty || !withdrawals.isEmpty
                    || ([.cancelled, .parkedCancelled].contains(scenario) && !reads.isEmpty)
            }
            XCTAssertEqual(finals.filter { $0 == text }.count, scenario == .interleaved ? 2 : 1)
        }
        let read = try XCTUnwrap(turns.last)
        let silent: [Scenario] = [.duplicatePark, .replacedAtFinal, .askAppears, .fragment, .dictation]
        XCTAssertEqual(reads, silent.contains(scenario) ? [] : [read])
        let expected = [.receipt, .interleaved].contains(scenario) ? [uncertain] : (scenario == .unknown ? [unknown] : [])
        XCTAssertEqual(cards, expected)
        XCTAssertEqual(parkedCards, [.singleChoice, .ambiguousAsk].contains(scenario) ? [uncertain] : (scenario == .parkedUnknown ? [unknown] : []))
        XCTAssertTrue(deliberateAnswers.isEmpty)
        if [.duplicatePark, .replacedAtFinal, .replacedAtCard, .parkedProtected, .askAppears, .fragment, .protectedCard, .missingOwner].contains(scenario) {
            XCTAssertEqual(withdrawals, [read])
        } else { XCTAssertTrue(withdrawals.isEmpty) }
        if scenario == .dictation { XCTAssertEqual(finals, [text]) }
        else if manual { XCTAssertNil(lane.turnID) }
        if scenario == .singleChoice {
            XCTAssertTrue(VoiceAdmissionContext.Ask.sameParkedSnapshot([choice], context.currentAsks))
            if !manual {
                try await capture("deliberate")
                try await push(final, item: item, words: text)
                try await push(final, item: "deliberate", words: "One.")
                try await until { !deliberateAnswers.isEmpty }
                XCTAssertEqual(deliberateAnswers, [choice.askID])
                XCTAssertEqual(parkedCards, [uncertain])
                XCTAssertTrue(context.currentAsks.isEmpty)
            }
        }
        let sent = await wire.frames()
        XCTAssertFalse(sent.contains { ["conversation.item.create", "response.create"].contains($0["type"]?.string) })
    }

    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VoiceError("Desktop status fixture timed out") }
            await Task.yield()
        }
    }
}

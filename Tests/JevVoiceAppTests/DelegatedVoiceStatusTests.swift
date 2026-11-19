import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class DelegatedVoiceStatusTests: XCTestCase {
    enum Outcome: CaseIterable { case current, unknown, replacedAtFinal, replacedAtDisplay, protectedCard, cancelled, pendingAsk, dictation }

    func testManualAndHandsFreeStatusIsLocalAndSingleUse() async throws {
        for manual in [false, true] {
            for outcome in Outcome.allCases where manual || outcome != .dictation {
                try await exercise(manual: manual, outcome: outcome)
            }
        }
    }

    func testStatusWordingRemainsAnAnswerToItsCapturedFreeformQuestion() {
        var context = VoiceAdmissionContext()
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .question)
        context.capturedAsks = [ask]; context.currentAsks = [ask]
        let words = "Has my delegated task finished?"
        let result = VoiceAdmissionPolicy.propose(words, context: context, speech: true)
        XCTAssertEqual(result.intent, "respond")
        XCTAssertEqual(result.replyTo, .init(taskID: ask.taskID, askID: ask.askID))
        context.currentAsks = []
        XCTAssertNotEqual(VoiceAdmissionPolicy.propose(words, context: context, speech: true).intent, "respond")
    }

    private func exercise(manual: Bool, outcome: Outcome) async throws {
        let wire = RecordedVoiceWire(), client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
        defer { if manual { lane.cancel() } else { lane.stopConversation() }; client.teardown() }
        var ledger = WorkerTurnLedger(agent: "fixture-private-worker", thread: "fixture-private-thread")
        let start = ledger.begin(), receipt = ledger.accept("fixture-private-turn", start: start)
        var context = VoiceAdmissionContext()
        context.delegatedStatus = .init(revision: UUID(), receipt: outcome == .unknown ? nil : receipt)
        if outcome == .pendingAsk {
            context.capturedAsks = [.init(taskID: UUID(), askID: UUID(), kind: .confirm)]
            context.currentAsks = context.capturedAsks
        }
        var cards = [String](), finals = [String](), began = false, reads = 0
        var displayOwner: UUID?, withdrawn = [UUID]()
        lane.conversation.readContext = { context }
        lane.conversation.onEvent = { event in
            if case .began(let id, _) = event { began = true; displayOwner = id }
            if case .final(_, let text) = event { finals.append(text) }
            if case .feedback = event { XCTFail("generic feedback") }
            if case .ignored(let id) = event { withdrawn.append(id) }
        }
        lane.conversation.interpret = { _, _, _ in XCTFail("semantic"); return .init(kind: .ignore) }
        lane.conversation.execute = { _ in XCTFail("executor"); throw CancellationError() }
        lane.conversation.onControl = { _ in XCTFail("control") }
        lane.onEvent = { _, event in
            if case .final(let text) = event { finals.append(text) }
            if case .toolSay = event { XCTFail("generic speech") }
        }
        lane.onLocalStatusCard = { id, text in
            XCTAssertEqual(id, displayOwner)
            guard outcome != .protectedCard else { return false }
            cards.append(text)
            return true
        }
        lane.onLocalStatusWithdrawn = { withdrawn.append($0) }
        lane.currentDelegatedScope = { id in
            return id == displayOwner && context.currentAsks.isEmpty ? context.delegatedStatus : nil
        }
        lane.workerStatus = { actual in
            reads += 1
            XCTAssertEqual(actual, receipt)
            if outcome == .replacedAtDisplay { context.delegatedStatus = .init(revision: UUID(), receipt: receipt) }
            if outcome == .cancelled { lane.cancel() }
            await Task.yield()
            return .workerFinished
        }
        lane.contextProvider = { XCTFail("generic context"); return "" }
        lane.screenShotProvider = { XCTFail("screenshot"); return nil }
        lane.commandHandler = { _, _, _, _, _, _ in XCTFail("new work"); return "{}" }
        lane.delegationHandler = { _, _, _, _, _ in XCTFail("new delegation"); return "{}" }
        let text = "Has my delegated task finished?"
        try await lane.prepareRealtimeTransport(manual ? .manual : .conversation)
        let item: String
        var task: Task<Void, Error>?
        if manual {
            item = await wire.audioItemID()
            let id = UUID()
            displayOwner = id
            let turn = try lane.beginRemoteManualInput(id: id, mode: outcome == .dictation ? .dictation : .command,
                                                       context: context, at: 0)
            task = Task {
                let result = try await lane.finalizeRemoteManualInput(turn)
                let admission = try XCTUnwrap(result)
                await lane.completeRemoteManualAdmission(admission)
                await lane.completeRemoteManualAdmission(admission)
            }
            try await until { await wire.frames().contains { $0["type"]?.string == "input_audio_buffer.commit" } }
        } else {
            item = "fixture-item"; try lane.beginRealtimeConversation(session: UUID())
            for kind in ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed"] {
                try await wire.push(["type": .string(kind), "item_id": .string(item)])
            }
            try await until { began }
        }
        if outcome == .replacedAtFinal { context.delegatedStatus = .init(revision: UUID(), receipt: receipt) }
        let final: [String: JSONValue] = ["type": .string("conversation.item.input_audio_transcription.completed"),
            "item_id": .string(item), "transcript": .string(text)]
        try await wire.push(final); try await wire.push(final)
        try await task?.value
        if !manual {
            try await until { !finals.isEmpty && (!withdrawn.isEmpty || !cards.isEmpty || (reads > 0 && outcome == .cancelled)) }
        }
        let expectedCards: [String] = outcome == .current ? [WorkerTurnStatus.workerFinished.localMessage]
            : outcome == .unknown ? [WorkerTurnStatus.unknown.localMessage] : []
        XCTAssertEqual(cards, expectedCards)
        if [.replacedAtFinal, .replacedAtDisplay, .pendingAsk, .protectedCard].contains(outcome) {
            XCTAssertEqual(withdrawn, [try XCTUnwrap(displayOwner)])
        }
        if !expectedCards.isEmpty { XCTAssertTrue(withdrawn.isEmpty) }
        if manual && outcome != .dictation { XCTAssertNil(lane.turnID) }
        XCTAssertEqual(reads, [.current, .replacedAtDisplay, .protectedCard, .cancelled].contains(outcome) ? 1 : 0)
        if outcome == .dictation { XCTAssertEqual(finals, [text]) }
        let sent = await wire.frames()
        XCTAssertFalse(sent.contains { ["response.create", "conversation.item.create"].contains($0["type"]?.string) })
    }

    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VoiceError("Status fixture timed out") }
            await Task.yield()
        }
    }
}

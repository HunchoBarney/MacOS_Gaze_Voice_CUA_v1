import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class SpokenGazeClickTests: XCTestCase {
    enum Case: CaseIterable { case fresh, coldOnset, changedAtFinal, revokedAtWrite, lostTurn, superseded, pendingAsk, freeform, lateSecondAsk, dictation, deictic }

    func testOnlyTheBareAffirmativeClickIsEligible() {
        for text in ["click", "Click.", " CLICK! "] { XCTAssertTrue(VoiceAdmissionPolicy.isBareGazeClick(text)) }
        for text in ["click?", "click..", "do not click", "click that", "click here", "click it", "right click",
                     "double click", "type click", "say click", "\"click\"", "click and send"] {
            XCTAssertFalse(VoiceAdmissionPolicy.isBareGazeClick(text))
        }
        XCTAssertNotEqual(VoiceAdmissionPolicy.propose("click", context: .init()).intent, "spoken_gaze_click")
        var context = VoiceAdmissionContext()
        context.capturedAsks = [.init(taskID: UUID(), askID: UUID(), kind: .choice, options: ["Click", "Back"])]
        context.currentAsks = context.capturedAsks
        XCTAssertEqual(VoiceAdmissionPolicy.propose("Click", context: context, speech: true).intent, "respond")
    }

    func testRealtimeManualAndConversationClickRequireOneUnchangedLease() async throws {
        for manual in [true, false] {
            for scenario in Case.allCases where manual ? ![.superseded, .lateSecondAsk].contains(scenario) : scenario != .dictation {
                try await exercise(manual: manual, scenario: scenario)
            }
        }
    }

    private func exercise(manual: Bool, scenario: Case) async throws {
        let wire = RecordedVoiceWire(), client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
        defer { if manual { lane.cancel() } else { lane.stopConversation() }; client.teardown() }
        let initialLease = UUID()
        var lease: UUID? = scenario == .coldOnset ? nil : initialLease
        var context = VoiceAdmissionContext()
        if scenario == .pendingAsk {
            context.capturedAsks = [.init(taskID: UUID(), askID: UUID(), kind: .confirm)]
            context.currentAsks = context.capturedAsks
        }
        let question = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .question)
        if scenario == .freeform || scenario == .lateSecondAsk {
            context.capturedAsks = [question]; context.currentAsks = [question]; context.selectedTask = question.taskID
        }
        var owner: UUID?, executorCalls = 0, writes = 0
        var replies: [String] = []
        var cards: [String] = [], withdrawals = 0, finishedExecutor = false, literal: String?, deicticRefusal = false
        lane.conversation.readContext = { context }
        lane.conversation.onEvent = { event in
            if case .began(let id, _) = event { owner = id }
            if case .ignored = event { withdrawals += 1 }
            if case .feedback = event {
                if scenario == .deictic || scenario == .lateSecondAsk { deicticRefusal = true } else { XCTFail("generic feedback") }
            }
        }
        lane.conversation.interpret = { _, _, _ in XCTFail("semantic"); return .init(kind: .ignore) }
        lane.conversation.beforeAction = {
            if scenario == .lateSecondAsk { context.currentAsks.append(.init(taskID: UUID(), askID: UUID(), kind: .question)) }
        }
        lane.conversation.execute = { command in
            XCTAssertEqual(scenario, .freeform)
            XCTAssertEqual(command.decision.kind, .answer)
            XCTAssertEqual(command.admission.replyTo?.taskID, question.taskID)
            XCTAssertEqual(command.admission.replyTo?.askID, question.askID)
            replies.append(command.text)
            return .init(verified: true, waitingForAnswer: false, message: "")
        }
        lane.exactTaskResponseHandler = { answer, task, ask, _ in
            XCTAssertEqual(scenario, .freeform)
            XCTAssertEqual(task, question.taskID); XCTAssertEqual(ask, question.askID)
            replies.append(answer)
            return "{}"
        }
        lane.conversation.onControl = { _ in XCTFail("control") }
        lane.onEvent = { _, event in
            if case .final(let text) = event { literal = text }
            if case .toolSay = event {
                if scenario == .deictic { deicticRefusal = true } else { XCTFail("unexpected speech") }
            }
        }
        lane.gazeClickLease = { lease }
        lane.gazeClickPermitted = { id in id == owner && context.currentAsks.isEmpty }
        lane.dispatchGazeClick = { bound, permitted in
            executorCalls += 1
            XCTAssertEqual(bound, initialLease)
            XCTAssertTrue(permitted())
            if scenario == .revokedAtWrite { lease = UUID() }
            if scenario == .lostTurn { lane.cancel() }
            if scenario == .superseded {
                let original = owner
                do {
                    try await wire.push(["type": .string("input_audio_buffer.speech_started"), "item_id": .string("next-item")])
                    try await self.until { owner != original }
                } catch { XCTFail("Next input did not take ownership: \(error)") }
            }
            await Task.yield()
            defer { finishedExecutor = true }
            guard permitted() else { return false }
            writes += 1
            return true
        }
        lane.settleGazeClick = { id, text in
            XCTAssertEqual(id, owner)
            if let text { cards.append(text); return true }
            withdrawals += 1
            return false
        }
        lane.commandHandler = { _, _, _, _, _, _ in XCTFail("generic action"); return "{}" }
        lane.contextProvider = { XCTFail("provider context"); return "" }
        lane.screenShotProvider = { XCTFail("screenshot"); return nil }
        try await lane.prepareRealtimeTransport(manual ? .manual : .conversation)
        let item: String
        var task: Task<Void, Error>?
        if manual {
            item = await wire.audioItemID()
            let id = UUID(); owner = id
            lane.captureManualGazeClickOnset(id)
            if scenario == .coldOnset { lease = initialLease }
            let turn = try lane.beginRemoteManualInput(id: id, mode: scenario == .dictation ? .dictation : .command,
                                                       context: context, at: 0)
            task = Task {
                let admission = try await lane.finalizeRemoteManualInput(turn)
                let result = try XCTUnwrap(admission)
                await lane.completeRemoteManualAdmission(result)
                await lane.completeRemoteManualAdmission(result)
            }
            try await until { await wire.frames().contains { $0["type"]?.string == "input_audio_buffer.commit" } }
        } else {
            item = "fixture-item"
            try lane.beginRealtimeConversation(session: UUID())
            for kind in ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed"] {
                try await wire.push(["type": .string(kind), "item_id": .string(item)])
            }
            try await until { owner != nil }
            if scenario == .coldOnset { lease = initialLease }
        }
        if scenario == .changedAtFinal { lease = UUID() }
        try await wire.push(["type": .string("conversation.item.input_audio_transcription.delta"),
                             "item_id": .string(item), "delta": .string("Click.")])
        let kind = "conversation.item.input_audio_transcription.completed"
        try await wire.push(["type": .string(kind), "item_id": .string("wrong-item"), "transcript": .string("Click.")])
        let final: [String: JSONValue] = ["type": .string(kind), "item_id": .string(item),
                                          "transcript": .string(scenario == .deictic ? "Click that." : "Click.")]
        try await wire.push(final); try await wire.push(final)
        try await task?.value
        if !manual {
            try await until { withdrawals > 0 || !cards.isEmpty || !replies.isEmpty || deicticRefusal
                || ([.lostTurn, .superseded].contains(scenario) && finishedExecutor) }
        }
        XCTAssertEqual(executorCalls, [.fresh, .revokedAtWrite, .lostTurn, .superseded].contains(scenario) ? 1 : 0)
        XCTAssertEqual(writes, scenario == .fresh ? 1 : 0)
        XCTAssertEqual(replies, scenario == .freeform ? ["Click."] : [])
        XCTAssertEqual(cards, scenario == .fresh ? ["Click requested."] : [])
        if scenario == .dictation { XCTAssertEqual(literal, "Click.") }
        else if manual { XCTAssertNil(lane.turnID) }
        if [.changedAtFinal, .coldOnset, .pendingAsk, .revokedAtWrite].contains(scenario) { XCTAssertEqual(withdrawals, 1) }
        let frames = await wire.frames()
        XCTAssertFalse(frames.contains { ["conversation.item.create", "response.create"].contains($0["type"]?.string) })
        let encoded = try JSONEncoder().encode(frames)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(initialLease.uuidString))
    }

    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VoiceError("Fixture timed out") }
            await Task.yield()
        }
    }
}

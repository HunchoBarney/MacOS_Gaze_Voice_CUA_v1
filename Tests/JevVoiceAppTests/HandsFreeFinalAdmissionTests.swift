import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class HandsFreeFinalAdmissionTests: XCTestCase {
    func testDesignFinals() async throws { try await run(split: "design", expectedCount: 30) }
    func testHeldOutFinals() async throws { try await run(split: "holdout", expectedCount: 19) }

    func testSemanticDecisionCannotCancelOrPauseWork() async throws {
        for kind in [ConversationDecision.Kind.stop, .pause] {
            let session = ConversationSession()
            defer { session.stop() }
            let context = VoiceAdmissionContext(targetAppID: "fixture.editor", windowID: 42)
            session.readContext = { context }
            session.makeSpeechSession = { context in
                let owner = LocalSpeechSession { _ in XCTFail("Unexpected automatic execution") }
                owner.context = context
                return owner
            }
            var interpreted = 0
            session.interpret = { _, _, _ in interpreted += 1; return .init(kind: kind) }
            session.onControl = { _ in XCTFail("An interpreter cannot authorize session control") }
            session.execute = { _ in XCTFail("Unexpected task"); throw CancellationError() }
            let done = expectation(description: "terminal feedback")
            session.onEvent = { if case .feedback = $0 { done.fulfill() } }
            try session.startExternal(session: UUID())
            let item = try session.beginExternal(input: .init(connectionID: UUID(), itemID: "item"), at: 0)
            XCTAssertTrue(session.commitExternal(item, at: 1))
            await session.finishExternal(item, text: "Organize these files by date.", at: 2)
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(interpreted, 1)
        }
    }

    func testUnrelatedArgumentsAreNotConversationControl() {
        for text in [#"search for "open source""#, "find files on Desktop 2"] {
            XCTAssertEqual(HandsFreeActionSyntax.parse(text), .other)
        }
        XCTAssertEqual(ConversationContext.localControl("Cancel."), .stop)
        XCTAssertEqual(HandsFreeActionSyntax.parse("Tell me whether I should stop."), .nonAction)
    }

    func testDisappearingCaptureBoundChoiceCannotBecomeCancel() async throws {
        let session = ConversationSession()
        defer { session.stop() }
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .choice, options: ["Continue", "Cancel"])
        var context = VoiceAdmissionContext()
        context.capturedAsks = [ask]; context.currentAsks = [ask]
        session.readContext = { context }
        session.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("Unexpected automatic execution") }
            owner.context = captured
            owner.onDecision = { XCTAssertEqual($0.reason, "ask_changed") }
            return owner
        }
        session.interpret = { _, _, _ in XCTFail("Stale choice reached interpretation"); return .init(kind: .stop) }
        session.execute = { _ in XCTFail("Stale choice created a task"); throw CancellationError() }
        session.onControl = { _ in XCTFail("Stale choice cancelled current work") }
        let done = expectation(description: "Stale choice refused")
        session.onEvent = { if case .feedback = $0 { done.fulfill() } }
        try session.startExternal(session: UUID())
        let item = try session.beginExternal(input: .init(connectionID: UUID(), itemID: "choice"), at: 0)
        XCTAssertTrue(session.commitExternal(item, at: 1))
        context.currentAsks = []
        await session.finishExternal(item, text: "Cancel", at: 2)
        await fulfillment(of: [done], timeout: 2)
    }

    func testNoSemanticDemotionForFocusInquiryOrNewAsk() async throws {
        for text in ["Focus Notes.", "Raise Notes?", "“Raise Notes”", "Should I stop?"] {
            let session = ConversationSession()
            defer { session.stop() }
            var context = VoiceAdmissionContext(targetAppID: "fixture.editor", windowID: 42)
            context.entities = [.init(name: "Notes", id: "fixture.notes", canOpenLocally: true)]
            session.readContext = { context }
            session.readPendingAsks = { text == "Focus Notes." ? [.init(taskID: UUID(), askID: UUID())] : [] }
            session.makeSpeechSession = { captured in
                let owner = LocalSpeechSession { _ in XCTFail("no automatic mutation") }; owner.context = captured
                return owner
            }
            session.interpret = { _, _, _ in XCTFail("must not demote to semantic task"); return .init(kind: .task) }
            session.remote = { _, _, _ in XCTFail("must not contact reasoning") }
            session.execute = { _ in XCTFail("must not start a task"); throw CancellationError() }
            session.onControl = { _ in XCTFail("must not cancel existing work") }
            let done = expectation(description: "refusal")
            session.onEvent = { if case .feedback = $0 { done.fulfill() } }
            try session.startExternal(session: UUID())
            let item = try session.beginExternal(input: .init(connectionID: UUID(), itemID: "fixture"), at: 0)
            XCTAssertTrue(session.commitExternal(item, at: 1))
            await session.finishExternal(item, text: text, at: 2)
            await fulfillment(of: [done], timeout: 2)
        }
    }

    func testAppScopeRejectsNewAmbiguityAndNewAsk() {
        let entity = VoiceAdmissionContext.Entity(name: "Notes", id: "fixture.notes", canOpenLocally: true)
        var captured = VoiceAdmissionContext()
        captured.entities = [entity]
        let decision = ConversationDecision(kind: .task, scope: .application(entity), local: true)
        XCTAssertTrue(decision.matchesCurrentScope(captured, captured: captured, final: "Focus Notes."))
        var current = captured
        current.entities.append(.init(name: "Notes", id: "fixture.other", canOpenLocally: true))
        XCTAssertFalse(decision.matchesCurrentScope(current, captured: captured, final: "Focus Notes."))
        current = captured
        current.currentAsks = [.init(taskID: UUID(), askID: UUID(), kind: .question)]
        XCTAssertFalse(decision.matchesCurrentScope(current, captured: captured, final: "Focus Notes."))
    }

    private func run(split: String, expectedCount: Int) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hands-free-final-admission.tsv")
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.components(separatedBy: "\t") }.filter { $0.count == 5 && $0[1] == split }
        XCTAssertEqual(rows.count, expectedCount)
        for row in rows {
            let (id, setup, final, expected) = (row[0], row[2], row[3], row[4])
            var context = VoiceAdmissionContext()
            context.targetAppID = "fixture.editor"; context.windowID = 42
            context.targetID = "window:17:42"; context.desktopDisplayID = 77
            context.editableTarget = setup == "editable" || setup == "dictation"
            context.entities = [.init(name: "Notes", id: "fixture.notes", canOpenLocally: true)]
            if setup == "duplicate-app" {
                context.entities.append(.init(name: "Notes", id: "fixture.notes2", canOpenLocally: true))
            }
            if setup == "dictation" {
                let owner = LocalSpeechSession { _ in XCTFail(id) }
                owner.context = context
                let input = VoiceRealtimeInput(connectionID: UUID(), itemID: id)
                let turn = owner.beginRemoteCapture(id: UUID(), mode: .dictation, connection: input.connectionID, now: 0)
                XCTAssertTrue(owner.commitRemoteCapture(turn, input: input, now: 1), id)
                let result = await owner.finishRemoteCapture(final, turn: turn, input: input, now: 2)
                XCTAssertEqual(result?.route, .dictation, id)
                XCTAssertEqual(result?.text, final, id)
                let duplicate = await owner.finishRemoteCapture(final, turn: turn, input: input, now: 2)
                XCTAssertNil(duplicate, id)
                continue
            }

            let session = ConversationSession()
            defer { session.stop() }
            var decisions: [VoiceAdmission] = [], commands: [ConversationCommand] = []
            let field = LiteralFixtureField()
            if expected == "literal:stop" { field.bind(session, app: "fixture.editor", window: 42) }
            var controls: [ConversationDecision.Kind] = [], remoteCalls = 0, interpretations = 0
            let settled = expectation(description: id)
            var settledOnce = false
            func settle() {
                guard !settledOnce else { return }
                settledOnce = true; settled.fulfill()
            }
            session.readContext = { context }
            session.makeSpeechSession = { capture in
                let owner = LocalSpeechSession { _ in XCTFail("Unexpected automatic execution: " + id) }
                owner.context = capture
                owner.onDecision = { decisions.append($0) }
                return owner
            }
            session.interpret = { _, _, _ in
                interpretations += 1
                return .init(kind: .task, scope: .window(app: "fixture.editor", id: 42))
            }
            session.remote = { _, _, execute in remoteCalls += 1; _ = try await execute(); settle() }
            session.execute = { command in
                commands.append(command)
                return .init(verified: false, waitingForAnswer: false, message: "Fixture finished.")
            }
            session.onControl = { controls.append($0) }
            session.beforeAction = {
                if setup == "window-changes" { context.windowID = 43 }
                if setup == "app-removed" { context.entities = [] }
                if setup == "display-changes" { context.desktopDisplayID = 78 }
            }
            try session.startExternal(session: UUID())
            func finish(_ text: String, item: String) async throws {
                let input = try session.beginExternal(input: .init(connectionID: UUID(), itemID: item), at: 0)
                XCTAssertTrue(session.commitExternal(input, at: 1), id)
                if setup == "ask-appears" {
                    context.currentAsks = [.init(taskID: UUID(), askID: UUID(), kind: .question)]
                }
                await session.finishExternal(input, text: text, at: 2)
                if setup == "duplicate-final" { await session.finishExternal(input, text: text, at: 2) }
            }
            if setup == "negative-fragment" {
                let held = expectation(description: id + "-fragment")
                session.onEvent = { if case .waiting = $0 { held.fulfill() } }
                try await finish("Don't", item: id + "-fragment")
                await fulfillment(of: [held], timeout: 2)
                decisions.removeAll()
            }
            session.onEvent = {
                switch $0 {
                case .feedback, .ignored, .waiting: settle()
                default: break
                }
            }
            try await finish(final, item: id)
            await fulfillment(of: [settled], timeout: 2)
            XCTAssertEqual(decisions.map(\.text), [final], id)
            if expected == "no_space" {
                XCTAssertFalse(commands.contains { $0.decision.space != nil }, id)
                XCTAssertTrue(controls.isEmpty, id)
                XCTAssertTrue(commands.allSatisfy { $0.text == final }, id)
                XCTAssertNotEqual(decisions.first?.intent, "switch_space", id)
                continue
            }
            if expected == "no_effect" {
                XCTAssertTrue(commands.isEmpty && controls.isEmpty, id)
                XCTAssertEqual(remoteCalls, 0, id)
                XCTAssertEqual(interpretations, 0, id)
                continue
            }
            if expected.hasPrefix("control:") {
                XCTAssertEqual(controls.map(\.rawValue), [String(expected.dropFirst(8))], id)
                XCTAssertTrue(commands.isEmpty, id)
            } else if expected == "literal:stop" {
                XCTAssertTrue(commands.isEmpty && controls.isEmpty, id)
                XCTAssertEqual(decisions.first?.intent, "type", id)
                XCTAssertEqual(decisions.first?.slots["text"], "stop", id)
                XCTAssertEqual(field.writes, 1, id)
                XCTAssertEqual(field.value, "stop", id)
            } else {
                XCTAssertEqual(commands.count, 1, id)
                let command = try XCTUnwrap(commands.first, id)
                XCTAssertEqual(command.text, final, id)
                XCTAssertTrue(controls.isEmpty, id)
                if expected.hasPrefix("space:") {
                    let n = try XCTUnwrap(Int(expected.dropFirst(6)), id)
                    XCTAssertEqual(command.decision.space, .numbered(n), id)
                    XCTAssertEqual(command.admission.intent, "switch_space", id)
                    XCTAssertEqual(command.admission.route, .local, id)
                    XCTAssertEqual(command.decision.scope, .window(app: "fixture.editor", id: 42), id)
                    XCTAssertEqual(command.context.desktopDisplayID, 77, id)
                } else if expected.hasPrefix("focus:") || expected.hasPrefix("launch:") {
                    XCTAssertEqual(command.decision.scope?.appID, "fixture.notes", id)
                    XCTAssertEqual(FastAction.openRequiresRaise(goal: final), expected.hasPrefix("focus:"), id)
                } else {
                    XCTAssertEqual(expected, "existing_show_desktop", id)
                    XCTAssertNil(command.decision.space, id)
                }
                XCTAssertTrue(command.decision.local, id)
            }
            XCTAssertEqual(remoteCalls, 0, id)
            XCTAssertEqual(interpretations, 0, id)
        }
    }
}

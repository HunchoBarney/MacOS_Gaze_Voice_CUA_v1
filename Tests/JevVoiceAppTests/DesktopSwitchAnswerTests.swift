import XCTest
import AVFoundation
import JevVoiceCore
@testable import JevVoice

@MainActor
final class DesktopSwitchAnswerTests: XCTestCase {
    private typealias Work = VoiceTaskCoordinator.Work
    private let session = UUID(), capture = UUID(), question = UUID(), connection = UUID()

    private func work(_ number: Int = 2, code: DesktopSpaceSwitch.Code? = .pressAcceptedUnverified,
                      origin: DesktopSpaceSwitch.Origin? = .startedOpen,
                      outcome: Work.Outcome = .uncertain("fixture")) -> Work {
        let request = "Go to Desktop \(number)."
        let work = Work(label: "Fixture", request: request, spec: DriveTask(goal: request))
        work.captureID = capture
        work.desktopSwitch = (number, 77)
        work.desktopDecision = code
        work.desktopOverviewOrigin = origin
        work.active = false
        work.outcome = outcome
        return work
    }

    private func recorded(_ work: Work, peers: [Work] = []) -> DesktopSwitchAnswers {
        var evidence = DesktopSwitchAnswers()
        let source = VoiceRealtimeInput(connectionID: connection, itemID: "request")
        evidence.begin(capture, conversation: session)
        evidence.source(source, for: capture)
        evidence.bind(work, to: capture, conversation: session, source: source, number: 2,
                      display: 77, works: [work] + peers, now: 10)
        return evidence
    }

    private func ask(_ evidence: inout DesktopSwitchAnswers, works: [Work] = [], at: TimeInterval = 12) -> String? {
        evidence.begin(question, conversation: session)
        evidence.source(.init(connectionID: connection, itemID: "question"), for: question)
        return evidence.answer(for: question, display: 77, works: works, now: at)
    }

    func testOnlyAcceptedPressAnswersFromExactTerminalWorkEvenAfterEviction() {
        let owned = work()
        owned.active = true; owned.outcome = nil; owned.desktopDecision = nil
        var evidence = recorded(owned)
        owned.active = false; owned.outcome = .uncertain("text must not be used"); owned.desktopDecision = .pressAcceptedUnverified
        evidence.observe([owned], now: 11)
        evidence.observe([], now: 12)
        XCTAssertEqual(ask(&evidence), "I requested Desktop 2, but I couldn’t verify the switch.")
        XCTAssertNil(evidence.answer(for: capture, display: 77, works: [], now: 12))
    }

    func testUnconfirmedPressIsNotNoSendAndOpeningIsNotArrival() {
        var refused = recorded(work(code: .pressRefused, origin: .launchRequested, outcome: .blocked("fixture")))
        XCTAssertEqual(ask(&refused), "I tried to select Desktop 2, but macOS didn’t confirm the request. Mission Control may be open.")
        var missing = recorded(work(code: .targetMissing, origin: .launchRequested, outcome: .blocked("fixture")))
        XCTAssertEqual(ask(&missing), "I didn’t send a selection for Desktop 2. Mission Control may be open.")
    }

    func testAbsentGenericDoneNoOpCancellationAndAmbiguousOwnersNeverClaimSwitch() {
        var absent = DesktopSwitchAnswers()
        XCTAssertEqual(ask(&absent), DesktopSwitchAnswers.unknown)
        for outcome in [Work.Outcome.done, .alreadyDone, .cancelled] {
            let generic = work(outcome: outcome)
            generic.dispatchedEffect = true
            var evidence = recorded(generic)
            XCTAssertEqual(ask(&evidence), DesktopSwitchAnswers.unknown)
        }
        var ambiguous = recorded(work(), peers: [work()])
        XCTAssertEqual(ask(&ambiguous), DesktopSwitchAnswers.unknown)
        var noDecision = recorded(work(code: nil, outcome: .done))
        XCTAssertEqual(ask(&noDecision), DesktopSwitchAnswers.unknown)
    }

    func testExpiredForeignSessionAndInterveningTurnCannotBorrowEvidence() {
        var expired = recorded(work())
        XCTAssertEqual(ask(&expired, at: 41), DesktopSwitchAnswers.unknown)
        var other = recorded(work())
        other.begin(question, conversation: UUID())
        other.source(.init(connectionID: connection, itemID: "question"), for: question)
        XCTAssertEqual(other.answer(for: question, display: 77, works: [], now: 12), DesktopSwitchAnswers.unknown)
        var interposed = recorded(work())
        interposed.begin(UUID(), conversation: session)
        XCTAssertEqual(ask(&interposed), DesktopSwitchAnswers.unknown)
        var foreign = recorded(work())
        foreign.begin(question, conversation: session)
        foreign.source(.init(connectionID: UUID(), itemID: "question"), for: question)
        XCTAssertEqual(foreign.answer(for: question, display: 77, works: [], now: 12), DesktopSwitchAnswers.unknown)
    }

    func testReplacementRetargetOrLateCompletionCannotUpgradeAnOnsetSnapshot() {
        let old = work()
        var duplicate = recorded(old)
        duplicate.observe([work()], now: 11)
        XCTAssertEqual(ask(&duplicate), DesktopSwitchAnswers.unknown)
        var altered = recorded(old)
        old.desktopSwitch = (3, 77)
        XCTAssertEqual(ask(&altered, works: [old]), DesktopSwitchAnswers.unknown)
        let pending = work()
        pending.active = true; pending.outcome = nil
        var late = recorded(pending)
        XCTAssertEqual(ask(&late, works: [pending]), DesktopSwitchAnswers.unknown)
        pending.active = false; pending.outcome = .uncertain("fixture")
        XCTAssertEqual(late.answer(for: question, display: 77, works: [pending], now: 13), DesktopSwitchAnswers.unknown)
    }

    func testManualSuccessorTakesOnlyItsFrozenPredecessor() {
        var evidence = recorded(work())
        evidence.begin(question, conversation: nil)
        XCTAssertEqual(evidence.answer(for: question, display: 77, works: [], now: 12),
                       "I requested Desktop 2, but I couldn’t verify the switch.")
        XCTAssertEqual(evidence.answer(for: question, display: 12, works: [], now: 12), DesktopSwitchAnswers.unknown)
        XCTAssertEqual(evidence.answer(for: question, display: 77, works: [], now: 12), DesktopSwitchAnswers.unknown)
        let next = UUID()
        evidence.begin(next, conversation: nil)
        XCTAssertEqual(evidence.answer(for: next, display: 77, works: [], now: 13), DesktopSwitchAnswers.unknown)
    }

    func testRetryOrConflictingQuestionWorkWithdrawsBoundEvidence() {
        let old = work()
        var retried = recorded(old)
        retried.invalidate()
        XCTAssertEqual(ask(&retried), DesktopSwitchAnswers.unknown)
        var conflict = recorded(old)
        let other = work()
        other.captureID = question
        XCTAssertEqual(ask(&conflict, works: [old, other]), DesktopSwitchAnswers.unknown)
        XCTAssertEqual(conflict.answer(for: question, display: 77, works: [], now: 13), DesktopSwitchAnswers.unknown)
    }

#if DEBUG
    private struct Keys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private enum Followup: CaseIterable {
        case automatic, manual, latched, interrupted, parkedAutomatic, parkedLatch, parkedExpiry, parkedTakeover
        var parked: Bool { [.parkedAutomatic, .parkedLatch, .parkedExpiry, .parkedTakeover].contains(self) }
        var isManual: Bool { self != .automatic && self != .parkedAutomatic }
        var latch: Bool { isManual && self != .manual }
    }

    func testControllerDesktopWorkSettlesIntoOnlyItsFollowingStatusAtPhysicalEdges() async throws {
        let prior = VoiceTaskCoordinator.accuracyReportURL
        VoiceTaskCoordinator.accuracyReportURL = nil
        defer { VoiceTaskCoordinator.accuracyReportURL = prior }
        for scenario in Followup.allCases { try await exercise(scenario) }
    }

    private func exercise(_ scenario: Followup) async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = Config(defaults: defaults, keyStore: Keys(), openAIKeyStore: Keys(), environment: [:])
        config.handsFreeEnabled = true; config.handsFreePaused = false; config.latchMode = true
        config.sounds = false; config.ttsEnabled = false; config.alwaysAllowComputerUse = true
        let cua = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } }), defaults: defaults),
            overlay: TargetOverlay(presentsPanels: false), resolver: AppResolver(listApps: { [] }),
            commandDriver: { _, _ in XCTFail("Unexpected driver request"); throw CancellationError() }, observeAgents: false)
        let automatic = RecordedVoiceWire(), manual = RecordedVoiceWire(), opens = LockedBox(0)
        let client = RealtimeVoiceClient(wireFactory: { _ in
            let index = opens.value; opens.set(index + 1)
            return index == 0 ? automatic : manual
        })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
        var grantManualStart = true
        let controller = VoiceController(config: config, speech: lane, authorize: {
            defer { grantManualStart = false }
            return grantManualStart
        }, frontmost: { nil }, cuaRuntime: cua, diagnosticTraceOnly: false, permissionStatusReader: { [] })
        defer { controller.cancel(); lane.stopConversation(); client.teardown(); cua.shutdown() }
        func context() -> VoiceAdmissionContext {
            var value = VoiceAdmissionContext(targetAppID: "fixture.editor", windowID: 42, desktopDisplayID: 77)
            value.capturedAsks = VoiceController.pendingVoiceAsks(in: cua.tasks)
            value.currentAsks = value.capturedAsks
            return value
        }
        controller.recordedVoiceInputs = (context, { true }, { id in
            try await lane.prepareRealtimeTransport(.manual)
            let turn = try lane.beginRemoteManualInput(id: id, mode: .command, context: context(),
                                                       at: ProcessInfo.processInfo.systemUptime)
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 24_000, channels: 1, interleaved: true))
            let feed = try ConvertedAudioFeed(input: format, output: format)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            memset(buffer.int16ChannelData![0], 0, 9_600)
            feed.append(buffer); feed.finish()
            let session = RealtimeVoiceLane.Session(name: "fixture", feed: feed, sendsAudio: true)
            session.localTurn = turn; lane.active = (id, session)
            return "fixture"
        })
        var calls = 0, answered: String?, parkEnded = false, parkBegan = 0.0
        cua.askExpirySeconds = scenario == .parkedExpiry ? 1.5 : 30
        cua.switchDesktop = { [weak cua] n, display, current, _ in
            calls += 1
            XCTAssertEqual(n, 2); XCTAssertEqual(display, 77); XCTAssertTrue(current())
            if scenario.parked, let cua, let work = cua.tasks.first {
                parkBegan = ProcessInfo.processInfo.systemUptime
                answered = await cua.park(.choice(prompt: "Pick a label", options: ["Did it switch?", "Maple"]), on: work)
                parkEnded = true
                return .init(.policyDenied, "Fixture ended.")
            }
            return .init(.pressAcceptedUnverified, "Switch unverified.", origin: .startedOpen)
        }
        cua.gazeContextProvider = { XCTFail("Unexpected gaze lookup"); return nil }
        lane.workerStatus = { _ in XCTFail("Unexpected worker lookup"); return .unknown }
        lane.contextProvider = { XCTFail("Unexpected provider context"); return "" }
        lane.screenShotProvider = { XCTFail("Unexpected capture"); return nil }
        lane.conversation.interpret = { _, _, _ in XCTFail("Unexpected model routing"); return .init(kind: .ignore) }
        let execute = try XCTUnwrap(lane.conversation.execute)
        var settled = false
        lane.conversation.execute = { command in
            let effect = try await execute(command)
            settled = true
            return effect
        }
        var tookOverAtQuestion = false
        defer { cua.audioFeedbackAllowed = { false } }
        if scenario == .parkedTakeover {
            config.sounds = true
            cua.audioFeedbackAllowed = {
                if !tookOverAtQuestion, cua.tasks.first?.awaitingChoice == true {
                    XCTAssertFalse(settled)
                    tookOverAtQuestion = true
                    controller.physicalFnChanged(true); controller.begin()
                }
                return false
            }
        }
        let show = try XCTUnwrap(lane.onLocalStatusCard)
        var cards = 0
        lane.onLocalStatusCard = { id, text in cards += 1; return show(id, text) }
        var reads = 0
        let read = try XCTUnwrap(lane.desktopSwitchAnswer)
        lane.desktopSwitchAnswer = { id, display in reads += 1; return read(id, display) }
        func utter(_ item: String, _ words: String) async throws {
            for kind in ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed"] {
                try await automatic.push(["type": .string(kind), "item_id": .string(item)])
            }
            try await automatic.push(["type": .string("conversation.item.input_audio_transcription.completed"),
                                      "item_id": .string(item), "transcript": .string(words)])
        }
        func until(line: Int = #line, _ condition: () async -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(3)
            while !(await condition()) {
                guard ContinuousClock.now < end else { throw VoiceError("Desktop status fixture: \(scenario) at \(line)") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        try await lane.prepareRealtimeTransport(.conversation)
        try lane.beginRealtimeConversation(session: UUID())
        lane.onConversationState?(.listening)
        try await utter("switch", "Go to Desktop 2.")
        try await until { scenario == .parkedTakeover ? tookOverAtQuestion : settled }
        let work = try XCTUnwrap(cua.tasks.first), id = work.askID
        XCTAssertEqual(work.awaitingAnswer, scenario.parked)
        XCTAssertEqual(work.desktopDecision, scenario.parked ? nil : .pressAcceptedUnverified)
        if scenario.isManual {
            if !tookOverAtQuestion { controller.physicalFnChanged(true); controller.begin() }
            try await until { controller.isListening }
            controller.physicalFnChanged(false)
            if scenario.latch {
                controller.latchHold(); controller.finish()
                XCTAssertTrue(controller.isListening)
                controller.physicalFnChanged(true)
            }
            controller.finish()
            try await until { await manual.frames().contains { $0["type"] == .string("input_audio_buffer.commit") } }
            if scenario == .interrupted { controller.cancelCaptureAttempt() }
            let item = await manual.audioItemID()
            try await manual.push(["type": .string("conversation.item.input_audio_transcription.completed"),
                                   "item_id": .string(item), "transcript": .string("Did it switch?")])
        } else {
            try await utter("question", "Did it switch?")
        }
        if scenario == .interrupted {
            try await until { lane.turnID == nil }
            XCTAssertEqual(cards, 0); XCTAssertNil(controller.parkedDesktopStatus)
        } else if scenario.parked {
            try await until { controller.parkedDesktopStatus != nil }
            XCTAssertEqual(controller.parkedDesktopStatus?.message, DesktopSwitchAnswers.unknown)
            XCTAssertEqual(controller.detail, "Pick a label"); XCTAssertEqual(work.askID, id)
            XCTAssertTrue(work.awaitingChoice); XCTAssertFalse(parkEnded)
            XCTAssertEqual(cards, 0); XCTAssertEqual(reads, 1)
            if scenario.latch { controller.physicalFnChanged(false) }
            if scenario == .parkedExpiry {
                try await until { parkEnded }
                XCTAssertNil(answered)
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - parkBegan, 2.5)
            } else {
                _ = await cua.respondToTaskExact("Choose one", taskID: work.id, askID: id, captureID: UUID())
                try await until { parkEnded }
                XCTAssertEqual(answered, "0")
            }
            XCTAssertNil(controller.parkedDesktopStatus)
        } else {
            try await until { controller.resultMessage == "I requested Desktop 2, but I couldn’t verify the switch." }
            XCTAssertEqual(cards, 1); XCTAssertEqual(reads, 1)
        }
        controller.physicalFnChanged(false)
        XCTAssertEqual(calls, 1); XCTAssertEqual(cua.tasks.map(\.id), [work.id])
        let wireFrames = await automatic.frames() + manual.frames()
        XCTAssertFalse(wireFrames.contains { ["response.create", "conversation.item.create"].contains($0["type"]?.string) })
    }
#endif
}

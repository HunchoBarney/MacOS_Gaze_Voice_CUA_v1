import AVFoundation
import CoreML
import Synchronization
import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: the local speech lane degrades quietly — a transcriber with
/// no reachable model cache lands in `.failed` and never crashes, `ingest`
/// never blocks the audio tap, and the voice surface speaks through an
/// injected engine with a working stop.
final class LocalSpeechTests: XCTestCase {
    func testConversationDeicticControlQuestionsNeverBecomeUnobservedGenericAnswers() {
        let context = VoiceAdmissionContext()
        for (words, expected) in [("What does this button do?", "screen_question"),
                                  ("What does that button do?", "screen_question"),
                                  ("What is that window?", "screen_question"),
                                  ("What is a button?", "question")] {
            let proposal = VoiceAdmissionPolicy.propose(words, context: context, speech: true)
            XCTAssertEqual(proposal.intent, expected, words)
            XCTAssertEqual(proposal.route, .remote)
            XCTAssertTrue(proposal.slots.isEmpty)
        }
    }

    @MainActor
    func testConversationRemoteFinalDesktopWaitsForAnOpenedEmptyListWithoutRelaunching() async {
        var inspections = 0, opens = 0, presses: [Int] = []
        let result = await DesktopSpaceSwitch.perform(number: 2, invalidation: { nil }, inspect: {
            inspections += 1
            let edges = [0: inspections == 1 ? [7] : [1], 1: [2], 2: [3], 3: [4], 4: inspections == 2 ? [] : [5]]
            let attrs: [Int: [String: Any]] = [
                1: ["AXIdentifier": "mc"], 2: ["AXIdentifier": "mc.display", "AXDisplayID": 9],
                3: ["AXIdentifier": "mc.spaces"], 4: ["AXIdentifier": "mc.spaces.list", "AXRole": "AXList"],
                5: ["AXDescription": "exit to Desktop 2", "AXRole": "AXButton"], 7: ["AXRole": "AXList"]
            ]
            return DesktopSpaceSwitch.overview(root: 0, displayID: 9, expected: "exit to Desktop 2",
                children: { edges[$0] }, attr: { attrs[$0]?[$1] }, pressable: { _ in true })
        }, open: { opens += 1 }, pause: {}, press: { presses.append($0); return true }, note: { _ in })
        XCTAssertEqual(inspections, 4); XCTAssertEqual(opens, 1); XCTAssertEqual(presses, [5])
        XCTAssertEqual(result.code, .pressAcceptedUnverified)
        XCTAssertEqual(result.origin, .launchRequested)
    }

    @MainActor
    func testConversationRemoteFinalDesktopInspectorClassifiesTheFirstFailingRead() throws {
        let dock = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app")))
        let desktop = dock.localizedString(forKey: "DesktopNum", value: "", table: "Localizable")
        let exit = dock.localizedString(forKey: "AXExitToDesktop", value: "", table: "Accessibility")
        XCTAssertEqual(desktop.components(separatedBy: "%@").count, 2)
        XCTAssertEqual(exit.components(separatedBy: "%@").count, 2)
        let expected = exit.replacingOccurrences(of: "%@", with: desktop.replacingOccurrences(of: "%@", with: "2"))
        var edges = [0: [1], 1: [2], 2: [3], 3: [4], 4: [6, 5]]
        var attributes: [Int: [String: Any]] = [
            1: ["AXIdentifier": "mc"], 2: ["AXIdentifier": "mc.display", "AXDisplayID": NSNumber(value: 9)],
            3: ["AXIdentifier": "mc.spaces"], 4: ["AXIdentifier": "mc.spaces.list", "AXRole": "AXList"],
            5: ["AXRole": "AXButton", "AXDescription": expected], 6: ["AXRole": "AXButton", "AXDescription": "fixture"],
            7: ["AXRole": "AXList"]
        ]
        var allow = true, checked: [Int] = []
        func inspect(displayID: UInt32 = 9) -> DesktopSpaceSwitch.Overview<Int> {
            checked = []
            return DesktopSpaceSwitch.overview(root: 0, displayID: displayID, expected: expected, children: { edges[$0] },
                attr: { attributes[$0]?[$1] }, pressable: { checked.append($0); return allow })
        }
        func refusal(_ code: DesktopSpaceSwitch.Code, checked count: Int = 0, displayID: UInt32 = 9, line: UInt = #line) {
            switch inspect(displayID: displayID) {
            case .openWithoutTarget(let observed), .unavailable(let observed): XCTAssertEqual(observed, code, line: line)
            default: XCTFail("Expected refusal", line: line)
            }
            XCTAssertEqual(checked.count, count, line: line)
        }
        guard case .target(5) = inspect() else { return XCTFail("Unique target not resolved") }
        XCTAssertEqual(checked, [5])
        let aliases: [(NSNumber, UInt32)] = [
            (NSNumber(value: UInt64(4_294_967_305)), 9), (NSNumber(value: 9.5), 9),
            (NSNumber(value: true), 1), (NSNumber(value: Int64(-1)), .max), (NSNumber(value: 0), 0)
        ]
        for (raw, captured) in aliases {
            attributes[2]?["AXDisplayID"] = raw
            refusal(.displayBindingUnavailable, displayID: captured)
        }
        attributes[2]?["AXDisplayID"] = NSNumber(value: UInt32.max)
        guard case .target(5) = inspect(displayID: .max) else { return XCTFail("Valid UInt32 refused") }
        attributes[2]?["AXDisplayID"] = NSNumber(value: 9)
        allow = false; refusal(.targetNotPressable, checked: 1)
        attributes[6]?["AXDescription"] = expected; refusal(.targetAmbiguous)
        attributes[5]?["AXDescription"] = nil; refusal(.malformedThumbnail)
        edges[4] = []; refusal(.emptySpacesList)
        edges[4] = nil; refusal(.spacesListUnavailable)
        edges[2] = []; refusal(.spacesGroupUnavailable)
        attributes[2]?["AXDisplayID"] = NSNumber(value: 99); refusal(.displayBindingUnavailable)
        edges[1] = nil; refusal(.overviewUnreadable)
        edges[0] = [7]; guard case .closed = inspect() else { return XCTFail("Expected closed overview") }
        attributes[7]?["AXRole"] = "AXGroup"; refusal(.rootUnrecognized)
        edges[0] = nil; refusal(.rootUnreadable)
    }

    @MainActor
    func testConversationRemoteFinalDesktopBoundaries() async {
        XCTAssertEqual(DesktopSpaceTarget(command: "Please switch to Space two."), .numbered(2))
        XCTAssertEqual(DesktopSpaceTarget(command: "next desktop"), .next)
        XCTAssertEqual(DesktopSpaceTarget(command: "go to the previous space"), .previous)
        for other in ["next window", "Mission Control", "type go to Desktop 2", "don't go to Desktop 2",
                      "go to Desktop 2 then click", "go to Desktop 2 on the other monitor",
                      "‘go to Desktop 2’", "Desktop 2", "go to Desktop 2?"] {
            XCTAssertNil(DesktopSpaceTarget(command: other), other)
        }
        let expected = "quitter vers Bureau 2"
        let rows = [("quitter vers Bureau 2 en plein écran", 10), (expected, 41), ("quitter vers Bureau 1", 72)]
        typealias State = DesktopSpaceSwitch.Overview<Int>
        func run(_ states: [State], authorized: Bool = true, revokeOnOpen: Bool = false,
                 openFails: Bool = false, pollFails: Bool = false, pressAccepted: Bool = true)
            async -> (opens: Int, presses: [Int], notes: [String], message: String, code: DesktopSpaceSwitch.Code, origin: DesktopSpaceSwitch.Origin?) {
            var states = states, current = authorized, opens = 0, presses: [Int] = [], notes: [String] = []
            let result = await DesktopSpaceSwitch.perform(number: 2, invalidation: { current ? nil : .authorityNotCurrent },
                inspect: { states.isEmpty ? .unavailable(.rootUnreadable) : states.removeFirst() },
                open: { opens += 1; if openFails { throw CancellationError() }; if revokeOnOpen { current = false } },
                pause: { if pollFails { throw CancellationError() } }, press: {
                    presses.append($0); return pressAccepted
                }, note: { notes.append($0) })
            return (opens, presses, notes, result.message, result.code, result.origin)
        }
        let target = DesktopSpaceSwitch.matchButton(rows, matching: expected)
        let delivered = await run([.closed, .closed, target, target])
        XCTAssertEqual(delivered.code, .pressAcceptedUnverified)
        XCTAssertEqual(delivered.opens, 1); XCTAssertEqual(delivered.presses, [41])
        XCTAssertTrue(delivered.message.contains("Switch unverified"))
        XCTAssertTrue(delivered.message.contains("Mission Control may be open"))
        XCTAssertTrue(delivered.notes.last?.contains("Mission Control may be open") == true)
        XCTAssertTrue(delivered.notes.last?.contains("selection may have been sent") == true)
        let existing = await run([.target(41), .target(41)])
        XCTAssertEqual(existing.origin, .startedOpen)
        XCTAssertEqual(existing.opens, 0); XCTAssertEqual(existing.presses, [41])
        let revoked = await run([.closed, .target(41)], revokeOnOpen: true)
        XCTAssertEqual(revoked.opens, 1); XCTAssertTrue(revoked.presses.isEmpty)
        XCTAssertTrue(revoked.message.contains("Mission Control may be open"))
        XCTAssertTrue(revoked.notes.first?.contains("Mission Control") == true)
        XCTAssertEqual(revoked.code, .authorityNotCurrent)
        let refused = await run([target, target], pressAccepted: false)
        XCTAssertEqual(refused.code, .pressRefused); XCTAssertEqual(refused.presses, [41])
        let cases: [([State], DesktopSpaceSwitch.Code, Int)] = [
            ([.unavailable(.rootUnrecognized)], .rootUnrecognized, 0),
            ([DesktopSpaceSwitch.matchButton(rows + [(expected, 32)], matching: expected)], .targetAmbiguous, 0),
            ([DesktopSpaceSwitch.matchButton(rows.map(Optional.some) + [nil], matching: expected)], .malformedThumbnail, 0),
            ([.closed, DesktopSpaceSwitch.matchButton(rows, matching: "exit to Desktop 2")], .targetMissing, 1),
            ([target, .unavailable(.spacesListUnavailable)], .spacesListUnavailable, 0),
            ([target, .closed], .overviewClosedOnRecheck, 0), ([target, .target(42)], .targetChanged, 0),
            ([.openWithoutTarget(.emptySpacesList), target], .emptySpacesList, 0),
            ([.closed, .openWithoutTarget(.emptySpacesList), .closed, target], .overviewClosedOnRecheck, 1),
            ([.closed, .unavailable(.displayBindingUnavailable), target], .displayBindingUnavailable, 1),
            ([.closed] + Array(repeating: .openWithoutTarget(.emptySpacesList), count: 12) + [target], .emptySpacesList, 1),
            (Array(repeating: .closed, count: 13), .overviewNotReady, 1)
        ]
        for (states, code, opens) in cases {
            let result = await run(states)
            XCTAssertEqual(result.code, code); XCTAssertEqual(result.opens, opens); XCTAssertTrue(result.presses.isEmpty)
            switch states.first {
            case .target?, .openWithoutTarget?: XCTAssertEqual(result.origin, .startedOpen)
            case .closed?: XCTAssertEqual(result.origin, .launchRequested)
            default: XCTAssertNil(result.origin)
            }
        }
        let denied = await run([.closed], authorized: false)
        XCTAssertEqual(denied.code, .authorityNotCurrent); XCTAssertEqual(denied.opens, 0); XCTAssertTrue(denied.presses.isEmpty)
        let launch = await run([.closed], openFails: true)
        XCTAssertEqual(launch.code, .openFailed); XCTAssertEqual(launch.opens, 1); XCTAssertTrue(launch.presses.isEmpty)
        let poll = await run([.closed, .closed], pollFails: true)
        XCTAssertEqual(poll.code, .pollInterrupted); XCTAssertEqual(poll.opens, 1); XCTAssertTrue(poll.presses.isEmpty)
    }

    @MainActor
    func testConversationRemoteFinalDesktopSwitchUsesOriginalFinalOnce() async throws {
        let conversation = ConversationSession()
        var context = VoiceAdmissionContext()
        context.targetAppID = "fixture.editor"; context.windowID = 42
        context.targetID = "fixture.editor.42"
        conversation.readContext = { context }
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("queue owns execution") }
            owner.context = captured
            return owner
        }
        let routed = expectation(description: "desktop request routed")
        var commands: [String] = []
        conversation.interpret = { _, _, _ in
            XCTFail("Desktop 2 missed the native route")
            routed.fulfill()
            return .init(kind: .clarify)
        }
        conversation.execute = { command in
            XCTAssertTrue(command.decision.local)
            XCTAssertEqual(command.admission.intent, "switch_space")
            commands.append(command.admission.text)
            routed.fulfill()
            return .init(verified: false, waitingForAnswer: false, message: "Unverified.")
        }
        var pending: String? = "A selection may have been sent. Mission Control may be open."
        conversation.pendingDesktopEffect = { pending }
        conversation.onControl = { _ in pending = nil }
        try conversation.startExternal(session: UUID())
        defer { conversation.stop() }
        let item = try conversation.beginExternal(input: .init(connectionID: UUID(), itemID: "desktop"), at: 1)
        XCTAssertTrue(conversation.commitExternal(item, at: 2))
        let final = "Go to Desktop 2."
        await conversation.finishExternal(item, text: final, at: 2.1)
        await conversation.finishExternal(item, text: final, at: 2.2)
        await fulfillment(of: [routed], timeout: 2)
        XCTAssertEqual(commands, [final])
        var spoken: String?
        conversation.onEvent = { if case .feedback(_, let text) = $0 { spoken = text } }
        let stop = try conversation.beginExternal(input: .init(connectionID: UUID(), itemID: "stop"), at: 3)
        XCTAssertTrue(conversation.commitExternal(stop, at: 4))
        await conversation.finishExternal(stop, text: "stop", at: 4.1)
        XCTAssertEqual(spoken, "Stopped. A selection may have been sent. Mission Control may be open.")
    }

    @MainActor
    func testConversationRemoteFinalRecoversFromEmptyAndUsesExistingNativeAdmissionOnce() async throws {
        let conversation = ConversationSession()
        var context = VoiceAdmissionContext()
        context.targetAppID = "fixture.editor"; context.windowID = 42
        context.targetID = "fixture.editor.42"
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("queue owns execution") }
            owner.context = captured
            return owner
        }
        conversation.readContext = { context }
        conversation.interpret = { _, _, _ in
            XCTFail("clear native scroll must not call a model")
            return .init(kind: .clarify)
        }
        var executed: [String] = []
        let effect = expectation(description: "next nonempty turn")
        conversation.execute = { command in
            executed.append(command.text)
            effect.fulfill()
            return .init(verified: true, waitingForAnswer: false, message: "Scrolled.")
        }
        conversation.onControl = { _ in }
        let session = UUID(), connection = UUID()
        try conversation.startExternal(session: session)
        defer { conversation.stop() }
        let empty = try conversation.beginExternal(
            input: .init(connectionID: connection, itemID: "empty"), at: 1)
        XCTAssertTrue(conversation.commitExternal(empty, at: 2))
        await conversation.finishExternal(empty, text: "", at: 2.1)
        XCTAssertEqual(conversation.id, session)
        let next = try conversation.beginExternal(
            input: .init(connectionID: connection, itemID: "next"), at: 3)
        XCTAssertTrue(conversation.commitExternal(next, at: 4))
        await conversation.finishExternal(next, text: "scroll down", at: 4.1)
        await conversation.finishExternal(next, text: "scroll down", at: 4.2)
        await fulfillment(of: [effect], timeout: 2)
        XCTAssertEqual(executed, ["scroll down"])
        XCTAssertEqual(conversation.id, session)
    }

    @MainActor
    func testRealtimeAdmissionNeedsNoLocalProviderAndKeepsDictationLiteral() async throws {
        let owner = LocalSpeechSession { _ in XCTFail("admission is not execution") }
        let input = VoiceRealtimeInput(connectionID: UUID(), itemID: "dictation-1")
        let turn = owner.beginRemoteCapture(id: UUID(), mode: .dictation,
            connection: input.connectionID, now: 0)
        let premature = await owner.finishRemoteCapture("Open Calculator. Don't change forty-two.",
            turn: turn, input: input, now: 0.5)
        XCTAssertNil(premature)
        XCTAssertTrue(owner.commitRemoteCapture(turn, input: input, now: 1))
        let final = await owner.finishRemoteCapture("Open Calculator. Don't change forty-two.",
            turn: turn, input: input, now: 1.1)
        XCTAssertEqual(final?.route, .dictation)
        XCTAssertEqual(final?.text, "Open Calculator. Don't change forty-two.")
        XCTAssertEqual(final?.realtimeInput, input)
        let duplicate = await owner.finishRemoteCapture("duplicate", turn: turn, input: input, now: 1.2)
        XCTAssertNil(duplicate)
    }

    @MainActor
    func testRealtimeEmptyFinalRetiresOnlyItsTurnAndRejectsLateOrForeignFinals() async throws {
        let owner = LocalSpeechSession { _ in XCTFail("no automatic execution") }
        let input = VoiceRealtimeInput(connectionID: UUID(), itemID: "empty")
        let first = owner.beginRemoteCapture(id: UUID(), mode: .command,
            connection: input.connectionID, now: 0)
        XCTAssertTrue(owner.commitRemoteCapture(first, input: input, now: 1))
        let empty = await owner.finishRemoteCapture(" \n", turn: first, input: input, now: 1.1)
        XCTAssertNil(empty)
        let nextInput = VoiceRealtimeInput(connectionID: input.connectionID, itemID: "next")
        let next = owner.beginRemoteCapture(id: UUID(), mode: .command,
            connection: input.connectionID, now: 2)
        XCTAssertTrue(owner.commitRemoteCapture(next, input: nextInput, now: 3))
        let stale = await owner.finishRemoteCapture("scroll down", turn: first, input: input, now: 3.1)
        let foreign = await owner.finishRemoteCapture("scroll down", turn: next, input: input, now: 3.1)
        XCTAssertNil(stale)
        XCTAssertNil(foreign)
        let final = await owner.finishRemoteCapture("What can you help with?", turn: next, input: nextInput, now: 3.2)
        XCTAssertEqual(final?.text, "What can you help with?")
        XCTAssertEqual(final?.realtimeInput, nextInput)
    }

    @MainActor
    func testConversationRecordedCapturePreservesFinalsAndRoutesOnlyGroundedLocalActions() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["JARVIS_CONVERSATION_VAD_RESOURCE"] else {
            throw XCTSkip("Pinned conversation VAD resource required")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audio = root.appendingPathComponent(".agent/results/P3/audio")
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: audio.appendingPathComponent("manifest.json"))) as? [String: Any])
        let recordings = try XCTUnwrap(manifest["recordings"] as? [[String: Any]])
        let fixture = try XCTUnwrap(recordings.last { $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true })
        let name = try XCTUnwrap(fixture["wav"] as? String)
        let source = try AVAudioFile(forReading: audio.appendingPathComponent(name))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 24_000, channels: 1, interleaved: true))
        let provider = LocalTranscriber()
        let owner = LocalSpeechSession(provider: provider) { _ in
            XCTFail("Automatic recording cannot enter the manual execution sink")
        }
        try await owner.prewarm()
        for observedApp in [true, false] {
            let feed = try ConvertedAudioFeed(input: source.processingFormat, output: format)
            let capture = ConversationCapture(modelDirectory: URL(fileURLWithPath: modelPath))
            let conversation = ConversationSession(capture: capture)
            var context = VoiceAdmissionContext()
            if observedApp {
                context.entities = [.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true)]
            }
            var semanticCalls = 0
            var executed: [UUID] = []
            conversation.readContext = { context }
            conversation.makeSpeechSession = { owner.recordedSession(context: $0) }
            conversation.interpret = { _, _, _ in
                semanticCalls += 1
                throw VoiceSemanticRouter.Failure.unavailable
            }
            conversation.execute = { command in
                XCTAssertTrue(observedApp, "Missing context and unavailable Jev must not reach execution")
                XCTAssertTrue(command.decision.local)
                XCTAssertEqual(command.decision.scope?.appID, "com.apple.calculator")
                executed.append(command.admission.turn.id)
                return .init(verified: true, waitingForAnswer: false, message: "Local execution spy")
            }
            conversation.onControl = { _ in XCTFail("No stop/pause was spoken") }
            try await conversation.prepare()
            var finals: [(UUID, String)] = []
            var sealed: [UUID] = []
            var failures: [String] = []
            let decoded = expectation(description: "two recorded utterances finalized; observed=\(observedApp)")
            decoded.expectedFulfillmentCount = 2
            let resolved = expectation(description: "both utterances resolved; observed=\(observedApp)")
            resolved.expectedFulfillmentCount = 2
            conversation.onEvent = { event in
                switch event {
                case .sealed(let id, _): sealed.append(id)
                case .final(let id, let text):
                    finals.append((id, text)); decoded.fulfill()
                case .feedback: resolved.fulfill()
                default: break
                }
            }
            conversation.onEnded = { _, reason in failures.append(reason) }
            try await conversation.start(feed: feed, session: UUID())
            defer { conversation.onControl = nil; conversation.stop(); feed.finish() }
            for _ in 0..<2 {
                source.framePosition = 0
                while source.framePosition < source.length {
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
                    try source.read(into: buffer)
                    feed.append(buffer)
                    try await Task.sleep(for: .seconds(Double(buffer.frameLength) / source.processingFormat.sampleRate))
                }
            }
            await fulfillment(of: [decoded, resolved], timeout: 45)
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
            XCTAssertEqual(finals.count, 2)
            XCTAssertEqual(Set(finals.map(\.0)).count, 2)
            XCTAssertEqual(sealed, finals.map(\.0))
            let prompt = try XCTUnwrap(fixture["prompt"] as? String)
            let words: (String) -> String = { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") }
            XCTAssertTrue(finals.allSatisfy { words($0.1) == words(prompt) }, finals.map(\.1).description)
            if finals.count == 2 { XCTAssertEqual(finals[0].1, finals[1].1) }
            XCTAssertEqual(executed, observedApp ? finals.map(\.0) : [])
            XCTAssertEqual(semanticCalls, observedApp ? 0 : 2)
            XCTAssertNotNil(conversation.id)
        }
    }

    func testConversationAdmissionIsOneShotAndCancellationRevokesIt() throws {
        for cancelled in [false, true] {
            var gate = VoiceTurnGate()
            let turn = gate.begin(mode: .command, ready: true, now: 1)
            XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
            XCTAssertTrue(gate.release(turn, acceptedFrames: 1, now: 2))
            XCTAssertNotNil(gate.finalize(turn, text: "scroll down",
                proposal: VoiceProposal(route: .local, intent: "scroll"),
                drainedFrames: 1, now: 2.1))
            if cancelled { gate.cancel(turn) }
            let admitted = gate.consume(turn)
            XCTAssertEqual(admitted != nil, !cancelled)
            XCTAssertNil(gate.consume(turn))
        }
    }

    func testSemanticResolutionCannotConsumeAConfirmationOrChangedTarget() {
        for reason in ["unclear_request", "ungrounded_target", "confirmation_required", "target_changed",
                       "ask_changed", "ambiguous_ask", "ambiguous_critical_value", "contradictory_request"] {
            var gate = VoiceTurnGate()
            let turn = gate.begin(mode: .command, ready: true, now: 1)
            XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
            XCTAssertTrue(gate.release(turn, acceptedFrames: 1, now: 2))
            XCTAssertNotNil(gate.finalize(turn, text: "A complete final",
                proposal: VoiceProposal(route: .clarify, intent: "blocked", reason: reason),
                drainedFrames: 1, now: 2.1))
            XCTAssertNil(gate.consume(turn))
            let resolved = gate.consume(turn, resolvingClarification: true)
            XCTAssertEqual(resolved != nil, ["unclear_request", "ungrounded_target"].contains(reason), reason)
            XCTAssertNil(gate.consume(turn, resolvingClarification: true))
        }
    }

    func testConversationTimelineRetainsTheNextTurnWhileTheFirstFinalizes() throws {
        var timeline = ConversationAudioTimeline()
        try timeline.append(4096)
        try timeline.beginSpeech(at: 0)
        try timeline.append(8192)
        XCTAssertEqual(try timeline.seal(at: 8192), 0..<8192)
        XCTAssertEqual(timeline.retained, 8192..<12288)
        try timeline.append(4096)
        try timeline.beginSpeech(at: 12288)
        XCTAssertEqual(try timeline.seal(at: 14336), 8192..<14336)
        XCTAssertEqual(timeline.retained, 14336..<16384)
    }

    func testConversationTimelineBoundsIdleButDoesNotTrimActiveSpeech() throws {
        var timeline = ConversationAudioTimeline(maximumSamples: 32_000, idleSamples: 16_000)
        for _ in 0..<100 { try timeline.append(4096) }
        XCTAssertEqual(timeline.retained.count, 16_000)
        let original = timeline.retained
        try timeline.beginSpeech(at: original.upperBound - 4096)
        try timeline.append(16_000)
        XCTAssertEqual(timeline.retained.lowerBound, original.lowerBound)
        let beforeOverflow = timeline.retained
        XCTAssertThrowsError(try timeline.append(1))
        XCTAssertEqual(timeline.retained, beforeOverflow)
        XCTAssertNotNil(timeline.activeStart)
    }

    func testConversationTimelineRejectsDuplicateOrImpossibleBoundaries() throws {
        var timeline = ConversationAudioTimeline()
        try timeline.append(4096)
        XCTAssertThrowsError(try timeline.beginSpeech(at: 4097))
        XCTAssertThrowsError(try timeline.beginSpeech(at: -1))
        try timeline.beginSpeech(at: 0)
        XCTAssertThrowsError(try timeline.beginSpeech(at: 10))
        XCTAssertThrowsError(try timeline.seal(at: 0))
        XCTAssertThrowsError(try timeline.seal(at: 4097))
        XCTAssertEqual(try timeline.seal(at: 3000), 0..<3000)
        XCTAssertThrowsError(try timeline.seal(at: 4000))
        XCTAssertEqual(timeline.retained, 3000..<4096)
    }

    func testConversationPaddingCannotReplayASpokenPriorTurn() throws {
        var timeline = ConversationAudioTimeline()
        try timeline.append(8192)
        try timeline.beginSpeech(at: 0)
        XCTAssertEqual(try timeline.seal(at: 7000), 0..<7000)
        try timeline.append(4096)
        try timeline.beginSpeech(at: 6500)
        XCTAssertEqual(timeline.activeStart, 7000)
        XCTAssertEqual(try timeline.seal(at: 11000), 7000..<11000)
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    @MainActor
    func testPermissionPollKeepsMainActorResponsiveAndCoalesces() async throws {
        let state = Mutex((reads: 0, onMain: false))
        let entered = expectation(description: "status reader entered")
        entered.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let delivered = expectation(description: "status applied")
        let monitor = PermissionStatusMonitor {
            state.withLock { value in value.reads += 1; value.onMain = Thread.isMainThread }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return [.camera]
        }
        monitor.refresh { missing in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(missing, [.camera])
            delivered.fulfill()
        }
        monitor.refresh { _ in XCTFail("A second polling task must not start") }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertFalse(state.withLock { $0.onMain })
        XCTAssertEqual(state.withLock { $0.reads }, 1)
        XCTAssertTrue(monitor.isRefreshing)
        release.signal()
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    func testPermissionPollInvalidationRejectsOlderGrantAndCanRefreshAgain() async throws {
        let entered = expectation(description: "old status read entered")
        let reads = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = PermissionStatusMonitor {
            let ordinal = reads.withLock { value in value += 1; return value }
            if ordinal == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
                return []
            }
            return [.microphone]
        }
        monitor.refresh { _ in XCTFail("Invalidated grant must not replace a newer explicit status") }
        await fulfillment(of: [entered], timeout: 1)
        monitor.invalidate()
        monitor.refresh { _ in XCTFail("Invalidating must not overlap a still-running system read") }
        XCTAssertTrue(monitor.isRefreshing)
        release.signal()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.isRefreshing, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(monitor.isRefreshing)
        let delivered = expectation(description: "new revocation applied")
        monitor.refresh {
            XCTAssertEqual($0, [.microphone])
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    @MainActor
    func testStoppedPermissionPollCannotDeliverOrRestart() async throws {
        let entered = expectation(description: "read entered before shutdown")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = PermissionStatusMonitor {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return []
        }
        monitor.refresh { _ in XCTFail("Shutdown must discard the outstanding status") }
        await fulfillment(of: [entered], timeout: 1)
        monitor.stop()
        release.signal()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.isRefreshing, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(monitor.isRefreshing)
        monitor.refresh { _ in XCTFail("A stopped poller must not wake capture") }
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    private final class PermissionCapture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var onReadiness: ((SpeechReadiness) -> Void)?
        var prepares = 0
        var suspends = 0
        var cancels = 0
        var prepareGate: CheckedContinuation<Void, Never>?
        var holdPreparation = false

        func prepare(inputUID: String?) async throws -> String {
            prepares += 1
            if holdPreparation { await withCheckedContinuation { prepareGate = $0 } }
            try Task.checkCancellation()
            onReadiness?(.ready("permission fixture"))
            return "permission fixture"
        }
        func suspend() async {
            suspends += 1
            prepareGate?.resume()
            prepareGate = nil
        }
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
            XCTFail("Permission polling must not start a voice hold")
            return "permission fixture"
        }
        func finish() {}
        func cancel() { cancels += 1 }
    }

    @MainActor
    func testAlreadyDeniedMicrophoneStatusDoesNotCancelUnrelatedInput() async throws {
        let capture = PermissionCapture()
        let config = Config(defaults: UserDefaults(suiteName: "c1-denied-permission-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        let controller = VoiceController(config: config, speech: capture,
            diagnosticTraceOnly: true, permissionStatusReader: { [.microphone, .camera] })
        controller.missingPermissions = [.microphone]
        let before = capture.cancels
        controller.refreshPermissionsInBackground(canPrepareMicrophone: { true }) {
            XCTFail("An unchanged denied permission cannot wake the microphone")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !controller.missingPermissions.contains(.camera),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(controller.missingPermissions.contains(.camera))
        XCTAssertEqual(capture.cancels, before)
        XCTAssertEqual(capture.suspends, 0)
        await controller.shutdown()
    }

    @MainActor
    func testPolledRevocationStopsPreparationAndGrantResumesOnceWhenActive() async throws {
        let status = Mutex<[Permission]>([])
        let reads = Mutex(0)
        let capture = PermissionCapture()
        capture.holdPreparation = true
        let config = Config(defaults: UserDefaults(suiteName: "c1-permission-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        let controller = VoiceController(config: config, speech: capture,
            diagnosticTraceOnly: true, permissionStatusReader: {
                reads.withLock { $0 += 1 }
                return status.withLock { $0 }
            })
        controller.missingPermissions = []
        controller.prepareMicrophone()
        var deadline = ProcessInfo.processInfo.systemUptime + 1
        while capture.prepareGate == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(capture.prepareGate)
        status.withLock { $0 = [.microphone] }
        var grants = 0
        var active = true
        func poll() {
            controller.refreshPermissionsInBackground(canPrepareMicrophone: { active }) {
                grants += 1
                controller.prepareMicrophone()
            }
        }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while capture.suspends == 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(capture.suspends, 0)
        XCTAssertFalse(controller.microphoneReady)
        XCTAssertTrue(controller.missingPermissions.contains(.microphone))
        capture.holdPreparation = false
        status.withLock { $0 = [] }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while !controller.microphoneReady, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(controller.microphoneReady)
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(capture.prepares, 2)
        let previous = reads.withLock { $0 }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while reads.withLock({ $0 }) == previous, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(reads.withLock { $0 }, 3)
        active = false
        controller.suspendMicrophone("Session inactive")
        status.withLock { $0 = [.microphone] }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while !controller.missingPermissions.contains(.microphone),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        status.withLock { $0 = [] }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while controller.missingPermissions.contains(.microphone),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.microphoneReady)
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(capture.prepares, 2)
        await controller.shutdown()
    }

    /// A directory that can never hold models — forces the download/load
    /// path to fail locally with zero network traffic.
    private let impossibleDir = URL(fileURLWithPath: "/dev/null/jevvoice-intelligence-test")

    private func makePCM(sampleRate: Double = 24_000, frames: Int = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Poll a condition up to `seconds` — the voice seam's work happens on
    /// a detached Task, so assertions wait rather than race it.
    private func waitFor(_ seconds: TimeInterval = 3,
                         _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// An arbitrary native tap must not become one long EOU process() call.
    /// Every slice is at most one ms160 encoder hop and no sample is lost.
    func testLargeNativePartialInputIsSplitWithoutDroppingSamples() {
        for count in [0, 1, 320, 1280, 1600, 4096, 16_000] {
            let ranges = LocalTranscriber.partialRanges(sampleCount: count)
            XCTAssertTrue(ranges.allSatisfy { !$0.isEmpty && $0.count <= 1280 })
            XCTAssertEqual(ranges.flatMap { Array($0) }, Array(0..<count))
        }
        XCTAssertEqual(LocalTranscriber.partialRanges(sampleCount: 4096).count, 4)
    }

    /// Additional diagnostic population, not a replacement for frozen h15:
    /// use its first 2.8s (phrase energy is around 1.5-2.5s), rather than
    /// waiting through the full recording's several seconds of trailing room
    /// audio. Both small replay packets and large native-sized packets must
    /// finalize safely with the real incumbent models and unchanged watchdog.
    @MainActor
    func testRecordedNaturalReleaseWithNativeSizedBuffers() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audio = root.appendingPathComponent(".agent/results/P3/audio")
        guard let bytes = try? Data(contentsOf: audio.appendingPathComponent("manifest.json")),
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let recordings = manifest["recordings"] as? [[String: Any]],
              let fixture = recordings.last(where: { $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true }),
              let name = fixture["wav"] as? String else {
            throw XCTSkip("confirmed private h15 recording required")
        }
        let provider = LocalTranscriber()
        guard FileManager.default.fileExists(
            atPath: LocalModelPaths.root.appendingPathComponent("parakeet-ultra").path) else {
            throw XCTSkip("real Parakeet models required")
        }
        try await provider.prepare()
        var calls = 0
        let session = LocalSpeechSession(provider: provider) { _ in calls += 1 }
        session.context.entities = [.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true)]
        for packetFrames in [320, 4096] {
            let file = try AVAudioFile(forReading: audio.appendingPathComponent(name))
            let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 24_000, channels: 1, interleaved: true))
            let feed = try ConvertedAudioFeed(input: file.processingFormat, output: output)
            let started = ProcessInfo.processInfo.systemUptime
            let turn = try await session.beginCapture(id: UUID(), mode: .command, now: started)
            let consumer = Task { @MainActor in
                var sequence = 0
                for try await buffer in feed.stream {
                    try await session.consume(VoicePCMFrame(copying: buffer), sequence: sequence,
                                              turn: turn, retainRemote: false)
                    sequence += 1
                }
            }
            defer { feed.finish(); consumer.cancel() }
            let end = min(file.length, AVAudioFramePosition(2.8 * file.processingFormat.sampleRate))
            while file.framePosition < end {
                let count = AVAudioFrameCount(min(Int64(packetFrames), end - file.framePosition))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
                try file.read(into: buffer, frameCount: count)
                feed.append(buffer)
                let until = started + Double(file.framePosition) / file.processingFormat.sampleRate
                let remaining = until - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            let released = ProcessInfo.processInfo.systemUptime
            feed.finish()
            let admission = try await session.finishCapture(turn, acceptedFrames: feed.emittedFrameCount(),
                releasedAt: released, capturedSeconds: feed.audioDurations().converted,
                drain: { try await consumer.value })
            XCTAssertEqual(admission?.route, .local, "packetFrames=\(packetFrames)")
            XCTAssertEqual(admission?.slots["target_id"], "com.apple.calculator")
        }
        XCTAssertEqual(calls, 2)
    }

    // MARK: - Transcriber states

    @MainActor
    func testRealNativeOverlapComputePlacement() async throws {
        guard let variant = ProcessInfo.processInfo.environment["JARVIS_P3_ASR_COMPUTE"],
              ["incumbent", "partial-gpu", "decoder-cpu"].contains(variant) else {
            throw XCTSkip("explicit serial native-compute experiment required")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audio = root.appendingPathComponent(".agent/results/P3/audio")
        let bytes = try Data(contentsOf: audio.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let recordings = try XCTUnwrap(manifest["recordings"] as? [[String: Any]])
        let fixture = try XCTUnwrap(recordings.last { $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true })
        let name = try XCTUnwrap(fixture["wav"] as? String)
        let source = try AVAudioFile(forReading: audio.appendingPathComponent(name))
        let nativeFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 1, interleaved: false))
        let resample = try ConvertedAudioFeed(input: source.processingFormat, output: nativeFormat)
        let collect = Task { @MainActor in
            var samples: [Float] = []
            for try await buffer in resample.stream {
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            return samples
        }
        while source.framePosition < source.length {
            let count = AVAudioFrameCount(min(4096, source.length - source.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count))
            try source.read(into: buffer, frameCount: count)
            resample.append(buffer)
        }
        resample.finish()
        let recordedNativeSamples = try await collect.value
        let provider = LocalTranscriber(
            partialComputeUnits: variant == "partial-gpu" ? .cpuAndGPU : nil,
            finalDecoderComputeUnits: variant == "decoder-cpu" ? .cpuOnly : .cpuAndNeuralEngine)
        try await provider.prepare()
        var calls = 0
        let session = LocalSpeechSession(provider: provider) { _ in calls += 1 }
        session.context.entities = [.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true)]
        for iteration in 0..<2 {
            let idleDeadline = ProcessInfo.processInfo.systemUptime + 10
            while !(await provider.partialDiagnostics.idle), ProcessInfo.processInfo.systemUptime < idleDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let idle = await provider.partialDiagnostics.idle
            XCTAssertTrue(idle, "old native partial must settle before this independent measurement")
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 24_000, channels: 1, interleaved: true))
            let feed = try ConvertedAudioFeed(input: nativeFormat, output: format)
            let started = ProcessInfo.processInfo.systemUptime
            let turn = try await session.beginCapture(id: UUID(), mode: .command, now: started)
            let consumer = Task { @MainActor in
                var sequence = 0
                for try await buffer in feed.stream {
                    try await session.consume(VoicePCMFrame(copying: buffer), sequence: sequence,
                                              turn: turn, retainRemote: false)
                    sequence += 1
                }
            }
            defer { feed.finish(); consumer.cancel() }
            let end = min(recordedNativeSamples.count, Int((iteration == 0 ? 2.8 : 6.0) * 48_000))
            for offset in stride(from: 0, to: end, by: 4096) {
                let count = min(4096, end - offset)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                try recordedNativeSamples.withUnsafeBufferPointer {
                    let base = try XCTUnwrap($0.baseAddress)
                    channel.update(from: base.advanced(by: offset), count: count)
                }
                let until = started + Double(offset + count) / 48_000
                let remaining = until - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                feed.append(buffer)
            }
            feed.finish()
            try await consumer.value
            let overlapDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            var nativeActive = await provider.partialDiagnostics.nativeActive
            while nativeActive == 0, ProcessInfo.processInfo.systemUptime < overlapDeadline {
                await Task.yield()
                nativeActive = await provider.partialDiagnostics.nativeActive
            }
            let released = ProcessInfo.processInfo.systemUptime
            var correct = false
            do {
                let admission = try await session.finishCapture(turn, acceptedFrames: feed.emittedFrameCount(),
                    releasedAt: released, capturedSeconds: feed.audioDurations().converted, drain: {})
                correct = admission?.route == .local && admission?.slots["target_id"] == "com.apple.calculator"
            } catch {
                XCTFail("native compute variant=\(variant) iteration=\(iteration) failed: \(error)")
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - released) * 1000
            print("NATIVE_COMPUTE variant=\(variant) iteration=\(iteration) active_at_release=\(nativeActive) correct=\(correct) release_final_ms=\(elapsed)")
            XCTAssertTrue(correct)
        }
        XCTAssertEqual(calls, 2)
    }

    private actor PartialSchedulingGate {
        var entered = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !opened else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    func testRealVoiceActivityIsOwnedThroughFinalCancelAndStaleCompletion() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audio = root.appendingPathComponent(".agent/results/P3/audio")
        guard FileManager.default.fileExists(atPath: audio.appendingPathComponent("manifest.json").path),
              FileManager.default.fileExists(atPath: LocalModelPaths.root.appendingPathComponent("parakeet-ultra").path) else {
            throw XCTSkip("confirmed recording and installed real models required")
        }
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: audio.appendingPathComponent("manifest.json"))) as? [String: Any])
        let recordings = try XCTUnwrap(manifest["recordings"] as? [[String: Any]])
        let fixture = try XCTUnwrap(recordings.last { $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true })
        let name = try XCTUnwrap(fixture["wav"] as? String)
        let file = try AVAudioFile(forReading: audio.appendingPathComponent(name))
        var frames: [VoicePCMFrame] = []
        let end = min(file.length, AVAudioFramePosition(2.8 * file.processingFormat.sampleRate))
        while file.framePosition < end {
            let count = AVAudioFrameCount(min(4096, end - file.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            try file.read(into: buffer, frameCount: count)
            frames.append(try VoicePCMFrame(copying: buffer))
        }
        let gate = PartialSchedulingGate()
        defer { Task { await gate.release() } }
        let provider = LocalTranscriber(beforeFinalDecode: { await gate.wait() })
        try await provider.prepare()
        func checkActivity(_ expected: Bool, line: UInt = #line) async {
            let active = await provider.partialDiagnostics.hasProcessActivity
            XCTAssertEqual(active, expected, line: line)
        }
        await checkActivity(false)
        let first = VoiceTurnToken(id: UUID(), generation: 1, mode: .command)
        try await provider.beginHold(first) { _, _ in }
        await checkActivity(true)
        for frame in frames { try await provider.appendHold(first, frame: frame) }
        let oldFinal = Task { try await provider.finishHold(first) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await gate.entered), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        await provider.cancelHold(first)
        await checkActivity(false)
        let second = VoiceTurnToken(id: UUID(), generation: 2, mode: .command)
        try await provider.beginHold(second) { _, _ in }
        await checkActivity(true)
        await provider.cancelHold(first)
        await checkActivity(true)
        await gate.release()
        do { _ = try await oldFinal.value; XCTFail("stale final must not publish") }
        catch { XCTAssertTrue(error is LocalSpeechError) }
        await checkActivity(true)
        for frame in frames { try await provider.appendHold(second, frame: frame) }
        let text = try await provider.finishHold(second)
        XCTAssertTrue(text.lowercased().contains("calculator"))
        await checkActivity(false)
        let third = VoiceTurnToken(id: UUID(), generation: 3, mode: .command)
        try await provider.beginHold(third) { _, _ in }
        await checkActivity(true)
        await provider.cancelHold(third)
        await checkActivity(false)
        let fourth = VoiceTurnToken(id: UUID(), generation: 4, mode: .command)
        try await provider.beginHold(fourth) { _, _ in }
        do { _ = try await provider.finishHold(fourth); XCTFail("empty hold must refuse") }
        catch { XCTAssertTrue(error is LocalSpeechError) }
        await checkActivity(false)
    }

    /// Only scheduling is controlled; all samples and final hypotheses come
    /// from the real confirmed recording and installed incumbent models.
    @MainActor
    func testWholeHoldFinalAndNextCaptureNeverJoinBlockedProvisionalWork() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audio = root.appendingPathComponent(".agent/results/P3/audio")
        guard let bytes = try? Data(contentsOf: audio.appendingPathComponent("manifest.json")),
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let recordings = manifest["recordings"] as? [[String: Any]],
              let fixture = recordings.last(where: { $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true }),
              let name = fixture["wav"] as? String,
              FileManager.default.fileExists(atPath: LocalModelPaths.root.appendingPathComponent("parakeet-ultra").path) else {
            throw XCTSkip("real confirmed h15 and installed models required")
        }
        let file = try AVAudioFile(forReading: audio.appendingPathComponent(name))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 24_000, channels: 1, interleaved: true))
        let feed = try ConvertedAudioFeed(input: file.processingFormat, output: format)
        let collect = Task { @MainActor in
            var frames: [VoicePCMFrame] = []
            for try await buffer in feed.stream { frames.append(try VoicePCMFrame(copying: buffer)) }
            return frames
        }
        let end = min(file.length, AVAudioFramePosition(2.8 * file.processingFormat.sampleRate))
        while file.framePosition < end {
            let count = AVAudioFrameCount(min(4096, end - file.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            try file.read(into: buffer, frameCount: count)
            feed.append(buffer)
        }
        feed.finish()
        let frames = try await collect.value
        let gate = PartialSchedulingGate()
        defer { Task { await gate.release() } }
        let provider = LocalTranscriber(beforePartialProcess: { await gate.wait() })
        try await provider.prepare()
        var executions = 0
        let session = LocalSpeechSession(provider: provider) { _ in executions += 1 }
        session.context.entities = [.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true)]
        for index in 0..<2 {
            let turn = try await session.beginCapture(id: UUID(), mode: .command,
                                                      now: ProcessInfo.processInfo.systemUptime)
            for (sequence, frame) in frames.enumerated() {
                try await session.consume(frame, sequence: sequence, turn: turn, retainRemote: false)
            }
            if index == 0 {
                for _ in 0..<100 {
                    if await gate.entered { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let entered = await gate.entered
                XCTAssertTrue(entered)
            }
            let result = try await session.finishCapture(turn, acceptedFrames: frames.count,
                releasedAt: ProcessInfo.processInfo.systemUptime, capturedSeconds: feed.audioDurations().converted) {}
            XCTAssertEqual(result?.route, .local)
            XCTAssertEqual(result?.slots["target_id"], "com.apple.calculator")
        }
        XCTAssertEqual(executions, 2)
        let pending = await provider.partialDiagnostics
        XCTAssertEqual(pending.resets, 1)
        XCTAssertEqual(pending.callbackInstalls, 1)
        XCTAssertEqual(pending.modelEntries, 0)
        XCTAssertFalse(pending.idle)
        await gate.release()
        for _ in 0..<100 {
            if await provider.partialDiagnostics.idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let drained = await provider.partialDiagnostics
        XCTAssertTrue(drained.idle)
        XCTAssertEqual(drained.modelEntries, 0, "released stale work cannot enter the model")
        let last = try await session.beginCapture(id: UUID(), mode: .command,
                                                 now: ProcessInfo.processInfo.systemUptime)
        for (sequence, frame) in frames.enumerated() {
            try await session.consume(frame, sequence: sequence, turn: last, retainRemote: false)
        }
        for _ in 0..<100 {
            if await provider.partialDiagnostics.modelEntries > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let resumed = await provider.partialDiagnostics
        XCTAssertEqual(resumed.resets, 2)
        XCTAssertEqual(resumed.callbackInstalls, 2)
        XCTAssertGreaterThan(resumed.modelEntries, 0, "later idle capture must resume real streaming")
        await provider.cancelHold(last)
    }

    func testTranscriberStartsUnloaded() async {
        let t = LocalTranscriber(modelsDirectory: impossibleDir)
        XCTAssertEqual(t.state, .unloaded)
    }

    /// start() against an unwritable model root must fail into `.failed`
    /// — quietly, without throwing or hanging.
    func testTranscriberFailedState() async {
        let t = LocalTranscriber(modelsDirectory: impossibleDir)
        await t.start()
        guard case .failed(let why) = t.state else {
            return XCTFail("expected .failed, got \(t.state)")
        }
        XCTAssertFalse(why.isEmpty)
        // A second start retries cleanly — the lane is never wedged.
        await t.start()
        guard case .failed = t.state else {
            return XCTFail("expected .failed again, got \(t.state)")
        }
    }

    /// ingest() is the tap-facing call: nonisolated, non-blocking, and a
    /// no-op before start — it must return instantly and never crash.
    func testIngestNeverBlocks() {
        let t = LocalTranscriber(modelsDirectory: impossibleDir)
        let buffer = makePCM()
        let start = Date()
        for _ in 0..<1000 { t.ingest(buffer) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    /// Callback assignment is the composition surface — it must not need
    /// an actor hop (the sink wire runs in sync context).
    func testCallbacksAssignSynchronously() {
        let t = LocalTranscriber(modelsDirectory: impossibleDir)
        let sawPartial = LockedBox(0)
        t.onPartial = { _ in sawPartial.set(1) }
        t.onFinal = { _ in }
        t.onUtteranceEnd = { }
        t.onProgress = { _ in }
        t.eouDebounceMs = 800
        XCTAssertEqual(t.eouDebounceMs, 800)
    }

    /// stop() on an unloaded/failed transcriber emits nothing and doesn't
    /// throw — the release path during a dead lane.
    func testStopQuietWhenUnloaded() async {
        let t = LocalTranscriber(modelsDirectory: impossibleDir)
        let finals = LockedBox<[String]>([])
        t.onFinal = { text in finals.set(finals.value + [text]) }
        await t.stop()
        XCTAssertTrue(finals.value.isEmpty)
    }

    // MARK: - Orphaned finalize

    /// Regression for the replay-observed poison: a deadline/cancel-orphaned
    /// finalize used to keep `activeHold`/`inFlight` until its decode
    /// drained, so every following capture failed busy/unavailable for
    /// minutes. cancelHold must release the hold at once, the orphan's
    /// owner-scoped defer must not clear a later turn's flags, and a stale
    /// partial completion must not erase a newer hold's flags. Needs real models —
    /// skips rather than fakes the provider.
    func testCancelledFinalizeDoesNotPoisonNextHold() async throws {
        let dir = LocalModelPaths.root
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("parakeet-ultra").path) else {
            throw XCTSkip("Parakeet models not installed on this machine")
        }
        let t = LocalTranscriber(modelsDirectory: dir)
        try await t.prepare()
        let t1 = VoiceTurnToken(id: UUID(), generation: 0, mode: .command)
        try await t.beginHold(t1) { _, _ in }
        // Bank >4800 resampled samples so finishHold reaches a real decode.
        for _ in 0..<20 {
            try await t.appendHold(t1, frame: try VoicePCMFrame(copying: makePCM()))
        }
        let orphan = Task { try? await t.finishHold(t1) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await t.cancelHold(t1)
        // Old deferred release kept the lane busy until the orphan drained.
        let t2 = VoiceTurnToken(id: UUID(), generation: 0, mode: .command)
        try await t.beginHold(t2) { _, _ in }
        // The second hold banks normally while old partial work is pending;
        // a stale completion cannot erase this hold's flags.
        for _ in 0..<20 {
            try await t.appendHold(t2, frame: try VoicePCMFrame(copying: makePCM()))
        }
        _ = try? await t.finishHold(t2)
        _ = await orphan.value
        // After both turns settle the lane is clean for the next capture.
        let freed = await waitFor(3) { t.readyForTurn }
        XCTAssertTrue(freed, "cancelled/orphaned finalize must free the lane")
        let t3 = VoiceTurnToken(id: UUID(), generation: 0, mode: .command)
        try await t.beginHold(t3) { _, _ in }
        await t.cancelHold(t3)
    }

    /// A provider whose final decode sleeps a fixed duration — pins the
    /// release→final deadline without touching real models.
    actor SlowProvider: LocalTranscriptProvider {
        nonisolated var readyForTurn: Bool { true }
        nonisolated var preparedForCapture: Bool { true }
        let delayNanoseconds: UInt64
        let appendDelayNanoseconds: UInt64
        let beginDelayNanoseconds: UInt64
        private(set) var appendStarted = false
        private(set) var beginStarted = false
        init(delay: TimeInterval, appendDelay: TimeInterval = 0, beginDelay: TimeInterval = 0) {
            delayNanoseconds = UInt64(delay * 1_000_000_000)
            appendDelayNanoseconds = UInt64(appendDelay * 1_000_000_000)
            beginDelayNanoseconds = UInt64(beginDelay * 1_000_000_000)
        }
        func prepare() async throws {}
        func beginHold(_ turn: VoiceTurnToken,
                       partial: @escaping @Sendable (VoiceTurnToken, String) -> Void) async throws {
            beginStarted = true
            if beginDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: beginDelayNanoseconds) }
        }
        func appendHold(_ turn: VoiceTurnToken, frame: VoicePCMFrame) async throws {
            appendStarted = true
            if appendDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: appendDelayNanoseconds) }
        }
        func finishHold(_ turn: VoiceTurnToken) async throws -> String {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return "open Calculator"
        }
        func cancelHold(_ turn: VoiceTurnToken) async {}
    }

    /// Physical-trial regression: a flat 1s release→final budget starved a
    /// 5.2s hold at 1006ms — finishHold cost is one in-flight EOU chunk join
    /// plus a whole-hold decode. This budget regression retains the sealed
    /// duration the caller vends covers frames still queued at release too —
    /// drain delivers them inside the budget they helped pay for.
    @MainActor
    func testFinalizeDeadlineScalesWithCapturedAudio() async throws {
        // ~6s sealed (300 × 20ms frames) → ~3.0s budget; a 2.3s decode fits.
        // Only 1s is consumed before release — the other 5s lands via drain,
        // which is exactly what the caller-supplied capturedSeconds must cover.
        let longSession = LocalSpeechSession(provider: SlowProvider(delay: 2.3)) { _ in }
        let longTurn = try await longSession.beginCapture(
            id: UUID(), mode: .command, now: ProcessInfo.processInfo.systemUptime)
        for i in 0..<50 {
            try await longSession.consume(try VoicePCMFrame(copying: makePCM()),
                                          sequence: i, turn: longTurn)
        }
        _ = try await longSession.finishCapture(
            longTurn, acceptedFrames: 300,
            releasedAt: ProcessInfo.processInfo.systemUptime, capturedSeconds: 6) {
            for i in 50..<300 {
                try await longSession.consume(try VoicePCMFrame(copying: self.makePCM()),
                                              sequence: i, turn: longTurn)
            }
        }

        // ~1s sealed → ~2.0s floor budget; a 2.3s decode still hits the cap.
        let shortSession = LocalSpeechSession(provider: SlowProvider(delay: 2.3)) { _ in }
        let shortTurn = try await shortSession.beginCapture(
            id: UUID(), mode: .command, now: ProcessInfo.processInfo.systemUptime)
        for i in 0..<50 {
            try await shortSession.consume(try VoicePCMFrame(copying: makePCM()),
                                           sequence: i, turn: shortTurn)
        }
        do {
            _ = try await shortSession.finishCapture(
                shortTurn, acceptedFrames: 50,
                releasedAt: ProcessInfo.processInfo.systemUptime, capturedSeconds: 1) {}
            XCTFail("a decode past a short hold's budget must throw deadline")
        } catch LocalSpeechError.deadline {}
    }

    @MainActor
    private func trialLane(provider: (any LocalTranscriptProvider)? = nil) -> VoiceLiveTrial.Lane {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                   channels: 1, interleaved: true)!
        return VoiceLiveTrial.Lane(
            session: LocalSpeechSession(provider: provider ?? SlowProvider(delay: 0)) { _ in },
            monitor: FnInputMonitor(), microphone: MicrophoneInput(),
            hardwareFormat: format, pcm: format)
    }

    @MainActor
    func testTrialCannotEraseHardwareInterruptionByArming() {
        let lane = trialLane()
        lane.interrupt("input stopped before capture")
        lane.arm()
        XCTAssertFalse(lane.armed)
        XCTAssertTrue(lane.failure?.contains("input stopped before capture") == true)
    }

    @MainActor
    func testTrialCannotRearmInterruptedCapture() {
        let lane = trialLane()
        lane.arm()
        lane.interrupt("input stopped during capture")
        lane.arm()
        XCTAssertFalse(lane.armed)
        XCTAssertTrue(lane.failure?.contains("input stopped during capture") == true)
    }

    /// Cancelling the previous case's sleep must not call abort on the next
    /// case (the former try? sleep swallowed CancellationError and did so).
    @MainActor
    func testTrialCompletedCaseDoesNotTimeoutNextCase() async throws {
        let lane = trialLane()
        lane.arm()
        let waiting = Task { @MainActor in await lane.waitOutcome(timeout: 0.05) }
        try await Task.sleep(nanoseconds: 10_000_000)
        lane.resolve()
        lane.arm()
        await waiting.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(lane.armed)
        XCTAssertNil(lane.failure, "a cancelled watchdog must not poison the next hold")
        lane.resolve()
    }

    /// Warmups must use the same bounded wait as scored cases.
    @MainActor
    func testTrialUnansweredWarmupTimesOutAndCanRetry() async {
        let lane = trialLane()
        lane.arm()
        await lane.waitOutcome(timeout: 0.02)
        XCTAssertFalse(lane.armed)
        XCTAssertNotNil(lane.failure)
        lane.arm()
        XCTAssertTrue(lane.armed)
        XCTAssertNil(lane.failure)
        lane.resolve()
    }

    /// A completion that arrives before waitOutcome installs its continuation
    /// must be latched, rather than hanging until a spurious timeout.
    @MainActor
    func testTrialCompletionBeforeWaitRemainsCompleted() async {
        let lane = trialLane()
        lane.arm()
        lane.resolve()
        await lane.waitOutcome(timeout: 0.02)
        XCTAssertNil(lane.failure)
        XCTAssertFalse(lane.armed)
    }

    /// Esc deliberately cancels an in-flight provider append. The consumer's
    /// catch must not turn that successful cancellation into capture loss.
    @MainActor
    func testTrialEscapeDuringAppendIsCancellationNotCaptureFailure() async throws {
        let provider = SlowProvider(delay: 0, appendDelay: 1)
        let lane = trialLane(provider: provider)
        lane.arm()
        await lane.begin(mode: .command)
        let frame = makePCM(frames: 4800)
        memset(frame.int16ChannelData![0], 0, Int(frame.frameLength) * 2)
        lane.microphone.gate.append(frame, at: AVAudioTime(hostTime: mach_absolute_time()))
        let deadline = Date().addingTimeInterval(1)
        while !(await provider.appendStarted), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await provider.appendStarted
        XCTAssertTrue(started, "the test must cancel a real in-flight append")
        let consumer = lane.consumer
        await lane.handle(.cancel)
        await consumer?.value
        await lane.waitOutcome(timeout: 0.02)
        XCTAssertNil(lane.failure)
        XCTAssertNil(lane.admission)
        XCTAssertEqual(lane.dispatchCount, 0)
        XCTAssertFalse(lane.armed)
    }

    @MainActor
    func testTrialReleaseDuringPreparationKeepsOriginalBoundaryAndRejects() async throws {
        let provider = SlowProvider(delay: 0, beginDelay: 0.1)
        let lane = trialLane(provider: provider)
        lane.arm()
        let begin = Task { @MainActor in await lane.begin(mode: .command) }
        let deadline = Date().addingTimeInterval(1)
        while !(await provider.beginStarted), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(lane.preparing)
        let release = ProcessInfo.processInfo.systemUptime
        await lane.handle(.finish)
        let recorded = lane.fnUp
        XCTAssertGreaterThanOrEqual(recorded, release)
        await begin.value
        XCTAssertEqual(lane.fnUp, recorded, "begin must not move the physical Fn-up")
        XCTAssertNil(lane.feed, "late preparation must not capture post-release speech")
        XCTAssertNil(lane.admission)
        XCTAssertNotNil(lane.failure)
        XCTAssertEqual(lane.dispatchCount, 0)
        XCTAssertFalse(lane.capturing)
        await lane.abort("test cleanup")
    }

    // MARK: - Voice seam

    /// Scripted engine — records speech, stays "saying" until cancelled so
    /// stop() has something to interrupt.
    final class FakeVoiceEngine: LocalVoiceEngine, @unchecked Sendable {
        let said = LockedBox<[String]>([])
        let cancels = LockedBox(0)
        var failPrepare = false
        /// Gate say() holds on — keeps an utterance in flight for stop().
        let holdOpen = LockedBox(true)
        func prepare() async throws {
            if failPrepare { throw LocalVoiceError.disabled }
        }
        func say(_ text: String) async throws {
            said.set(said.value + [text])
            // Simulate streamed playback — hold until cancelled so a
            // subsequent speak()/stop() has in-flight work to interrupt.
            while holdOpen.value && !Task.isCancelled {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if Task.isCancelled { throw CancellationError() }
        }
        func cancel() async { cancels.set(cancels.value + 1) }
    }

    func testSpeakRoutesThroughEngine() async {
        let engine = FakeVoiceEngine()
        engine.holdOpen.set(false)
        let voice = LocalVoice(engine: engine)
        voice.speak("hello there")
        let spoke = await waitFor { engine.said.value == ["hello there"] }
        XCTAssertTrue(spoke)
    }

    /// A second speak() replaces the first — the in-flight utterance's
    /// engine.cancel() runs before the new one speaks.
    func testSpeakInterruptsInFlight() async {
        let engine = FakeVoiceEngine()
        let voice = LocalVoice(engine: engine)
        voice.speak("first")
        let first = await waitFor { engine.said.value == ["first"] }
        XCTAssertTrue(first)
        engine.holdOpen.set(false)
        voice.speak("second")
        let both = await waitFor { engine.said.value == ["first", "second"] }
        XCTAssertTrue(both)
        XCTAssertGreaterThanOrEqual(engine.cancels.value, 1)
    }

    /// stop() cancels engine playback — SpeechSynthesizing's contract.
    func testStopSilencesEngine() async {
        let engine = FakeVoiceEngine()
        let voice = LocalVoice(engine: engine)
        voice.speak("interrupted")
        let heard = await waitFor { !engine.said.value.isEmpty }
        XCTAssertTrue(heard)
        voice.stop()
        let silenced = await waitFor { engine.cancels.value >= 1 }
        XCTAssertTrue(silenced)
    }

    /// An engine that can't prepare surfaces through prepare() → false and
    /// a logged miss on speak — never a throw through the sync protocol.
    func testEngineFailureDegrades() async {
        let engine = FakeVoiceEngine()
        engine.failPrepare = true
        let voice = LocalVoice(engine: engine)
        let ok = await voice.prepare()
        XCTAssertFalse(ok)
        voice.speak("anything") // must not crash
        voice.stop()
    }

    /// The license-review flag path: a disabled voice builds the silent
    /// stub and speaks nothing — but also never crashes.
    func testDisabledVoiceIsSilentStub() async {
        let voice = LocalVoice(enabled: false)
        _ = await voice.prepare()
        voice.speak("quiet")
        voice.stop()
    }

    /// Pocket frame conversion — Float32 [-1,1] → little-endian int16 at
    /// the exact wire format RealtimePlayer.enqueue expects.
    func testPocketFrameConversion() {
        let data = PocketVoiceEngine.int16PCM([0, 1, -1, 0.5, -0.5])!
        XCTAssertEqual(data.count, 10)
        let samples = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { $0 }
        }
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 32767)
        XCTAssertEqual(samples[2], -32767)
        XCTAssertEqual(samples[3], Int16((0.5 * 32767).rounded()))
        XCTAssertNil(PocketVoiceEngine.int16PCM([]))
    }

    /// Matching normalization cannot turn a longer phrase into cancellation.
    func testSharedNormalization() {
        XCTAssertEqual(VoiceAdmissionPolicy.normalized("  Stop. \n"), "stop")
        var context = VoiceAdmissionContext()
        context.tasks = [UUID()]
        XCTAssertEqual(VoiceAdmissionPolicy.propose("STOP!", context: context).intent, "cancel")
        XCTAssertEqual(VoiceAdmissionPolicy.propose("never mind", context: context).intent, "cancel")
        XCTAssertNotEqual(VoiceAdmissionPolicy.propose("stop by the store", context: context).route, .local)
    }
}

import XCTest
import AVFoundation
import Speech
import JarvisCore
@testable import Jarvis

/// L7 writing by instruction: the verbatim span, the on-device agreement
/// check, typing with read-back, and reply drafts that only "send it"
/// sends. Every seam is a fake: no microphone, Accessibility or network.
@MainActor
final class WritingByInstructionTests: XCTestCase {
    private final class FakeDesk {
        var value = ""
        var editable = true
        var pid: Int32 = 42
        var lands = true
        var inserts: [String] = []
        var shown: [[String]] = []
        var sent: [WritingByInstruction.Draft] = []
        var composed = 0
        var composedFrom: [String] = []
        var current = true
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    nonisolated private static let message = WritingByInstruction.Referent(text: "Are we still on for 5?", appName: "Mail",
                                                               windowTitle: "Dana")

    private func writer(_ desk: FakeDesk, local: String?, enabled: @escaping () -> Bool = { true },
                        referent: WritingByInstruction.Referent? = message,
                        reply: String = "Yes, see you at 5.\nI'll bring the notes.") -> WritingByInstruction {
        WritingByInstruction(
            enabled: enabled,
            localTranscript: { local },
            insert: { text in
                desk.inserts.append(text)
                if desk.lands { desk.value += text }
            },
            readField: {
                .init(value: desk.value, selectedText: nil, editable: desk.editable, appName: "Mail",
                      bundleID: "com.apple.mail", windowTitle: "Re: Dana", pid: desk.pid)
            },
            referent: { _ in referent },
            compose: { referent in
                desk.composed += 1
                desk.composedFrom.append(referent.text)
                return reply
            },
            send: { draft in
                desk.sent.append(draft)
                return VoiceToolResult(status: VoiceToolResult.Status.ok, say: "Sent.").encoded()
            },
            show: { desk.shown.append($0) })
    }

    private func field(_ payload: String?, _ key: String) -> String? {
        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    private static let literals: [(said: String, typed: String)] = [
        ("Type this: meet Siobhán at 5:45.", "meet Siobhán at 5:45"),
        ("type this 'see you at five'", "see you at five"),
        ("Type this, “Ça va? Où est Zoë… 😀”", "Ça va? Où est Zoë… 😀"),
        ("type this quote Dear Dr. O'Neil, the total is $1,234.50, end quote please",
         "Dear Dr. O'Neil, the total is $1,234.50"),
        ("Jarvis, can you type this: 東京 at 9", "東京 at 9"),
        ("write this down: call 555-0134 ext. 12", "call 555-0134 ext. 12"),
        ("type \"Hello, World.\"", "Hello, World."),
        ("Type the following: Jürgen's 3rd order #42 (rush)", "Jürgen's 3rd order #42 (rush)"),
        ("type 'don't stop'", "don't stop"),
        ("type this out: new line stays words", "new line stays words"),
    ]

    // MARK: - The verbatim span

    func testLiteralKeepsNamesNumbersUnicodeAndPunctuation() {
        for (said, typed) in Self.literals {
            XCTAssertEqual(WritingInstruction.literal(in: said), typed, said)
            XCTAssertEqual(WritingInstruction.intent(said), .type(literal: typed), said)
        }
    }

    func testOnlyWritingLeadInsCarryASpan() {
        for said in ["type hello in notes", "write an email to Dana", "open notes", "type", "type this",
                     "typewriter repair shops near me", "type 'unclosed quote", "please type this:  "] {
            XCTAssertNil(WritingInstruction.literal(in: said), said)
        }
    }

    func testLiteralsWithinFindTheRequestInsideLongerSpeech() {
        let transcript = "Open my mail. Okay, type this, see you at five. Thanks!"
        XCTAssertEqual(WritingInstruction.literals(within: transcript).first, "see you at five. Thanks")
        XCTAssertTrue(WritingInstruction.literals(within: "scroll down a bit and open notes").isEmpty)
    }

    func testAgreementIgnoresOnlyCaseAndPunctuation() {
        XCTAssertTrue(WritingInstruction.agrees("meet Siobhán at 5:45", "Meet siobhán at 5:45."))
        XCTAssertTrue(WritingInstruction.agrees("Zoë", "Zoe\u{0308}"))
        XCTAssertTrue(WritingInstruction.agrees("Dear Dr. O'Neil", "dear dr o'neil"))
        XCTAssertFalse(WritingInstruction.agrees("meet Siobhán", "meet Siobhan"))
        XCTAssertFalse(WritingInstruction.agrees("see you at five", "see you at 5"))
        XCTAssertFalse(WritingInstruction.agrees("5:45", "5:15"))
        XCTAssertFalse(WritingInstruction.agrees("", ""))
    }

    func testReplyAndSendIntents() {
        for said in ["come up with a reply for this", "Draft a response to that email.", "write a reply to this",
                     "Can you suggest an answer to this?"] {
            XCTAssertEqual(WritingInstruction.intent(said), .draftReply, said)
        }
        for said in ["send it", "Yes, send it.", "go ahead and send it", "send the reply please"] {
            XCTAssertEqual(WritingInstruction.intent(said), .sendDraft, said)
        }
        for (said, typed) in [("type this \"please write a reply to this\"", "please write a reply to this"),
                              ("write this down: draft a response to that email", "draft a response to that email"),
                              ("type 'come up with an answer for it'", "come up with an answer for it")] {
            XCTAssertEqual(WritingInstruction.intent(said), .type(literal: typed), said)
        }
        for said in ["reply to Dana saying hi", "send it to Dana", "what does this say"] {
            XCTAssertNotEqual(WritingInstruction.intent(said), .draftReply, said)
            XCTAssertNotEqual(WritingInstruction.intent(said), .sendDraft, said)
        }
    }

    // MARK: - Typing with read-back

    func testAgreedLiteralsTypeExactlyAndReadBack() async {
        for (said, typed) in Self.literals {
            let desk = FakeDesk()
            desk.value = "Hi Dana, "
            let payload = await writer(desk, local: "Open my mail. " + said.lowercased()).handle(said)
            XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.ok, said)
            XCTAssertEqual(desk.inserts, [typed], said)
            XCTAssertEqual(desk.value, "Hi Dana, " + typed, said)
            XCTAssertTrue(desk.shown.isEmpty, said)
        }
    }

    func testDisagreementIsShownBeforeAnythingIsTyped() async {
        let desk = FakeDesk()
        let writing = writer(desk, local: "type this meet Siobhan at 5:45")
        let asked = await writing.handle("Type this: meet Siobhán at 5:45")
        XCTAssertEqual(field(asked, "status"), VoiceToolResult.Status.question)
        XCTAssertTrue(desk.inserts.isEmpty)
        XCTAssertEqual(desk.shown.last?.contains("meet Siobhán at 5:45"), true)
        XCTAssertEqual(desk.shown.last?.contains("On-device heard: meet Siobhan at 5:45"), true)
        XCTAssertEqual(writing.pending, .type("meet Siobhán at 5:45"))

        let typed = await writing.handle("type it")
        XCTAssertEqual(field(typed, "status"), VoiceToolResult.Status.ok)
        XCTAssertEqual(desk.value, "meet Siobhán at 5:45")
        XCTAssertNil(writing.pending)
    }

    func testNoOnDeviceTranscriptMeansShownFirstAndNoTypesNothing() async {
        let desk = FakeDesk()
        let writing = writer(desk, local: nil)
        let asked = await writing.handle("type this see you at five")
        XCTAssertEqual(field(asked, "status"), VoiceToolResult.Status.question)
        let declined = await writing.handle("no")
        XCTAssertEqual(field(declined, "status"), VoiceToolResult.Status.cancelled)
        let late = await writing.handle("type it")
        XCTAssertNil(late)
        XCTAssertTrue(desk.inserts.isEmpty)
    }

    func testAnotherRequestDropsAnUnconfirmedLiteral() async {
        let desk = FakeDesk()
        let writing = writer(desk, local: nil)
        _ = await writing.handle("type this see you at five")
        let other = await writing.handle("open notes")
        XCTAssertNil(other)
        let yes = await writing.handle("yes")
        XCTAssertNil(yes)
        XCTAssertTrue(desk.inserts.isEmpty)
    }

    func testTextThatDoesNotLandIsReportedNotClaimed() async {
        let desk = FakeDesk()
        desk.lands = false
        let payload = await writer(desk, local: "type this hello").handle("type this hello")
        XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.error)
        XCTAssertEqual(desk.inserts, ["hello"])
    }

    func testAFieldThatCannotBeReadBackIsNotCountedAsTyped() async {
        let desk = FakeDesk()
        var reads = 0
        let writing = writer(desk, local: "type this hello")
        writing.readField = {
            reads += 1
            return .init(value: reads == 1 ? "" : nil, selectedText: nil, editable: true, appName: nil,
                         bundleID: nil, windowTitle: nil, pid: desk.pid)
        }
        let payload = await writing.handle("type this hello")
        XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.error)
        XCTAssertEqual(desk.inserts, ["hello"])
    }

    func testTranscriberGivesUpAtItsTimeoutEvenIfSpeechIgnoresCancellation() async {
        var transcriber = LocalSpanTranscriber()
        transcriber.authorization = { .authorized }
        transcriber.timeout = .milliseconds(20)
        transcriber.analyze = { _ in
            await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
            return "type this too late"
        }
        let started = ContinuousClock.now
        let text = await transcriber.transcribe(Data(count: 4_800))
        XCTAssertNil(text)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    func testNoEditableFieldTypesNothing() async {
        let desk = FakeDesk()
        desk.editable = false
        let payload = await writer(desk, local: "type this hello").handle("type this hello")
        XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.refused)
        XCTAssertTrue(desk.inserts.isEmpty)
    }

    func testReadBackFoldsTheQuotesEditorsSubstitute() {
        XCTAssertEqual(WritingByInstruction.count("don't \"stop\"", in: "I don’t “stop” and don't \"stop\""), 2)
        XCTAssertEqual(WritingByInstruction.count("a\nb", in: "a\r\nb"), 1)
    }

    // MARK: - Reply drafts

    func testDraftIsPlacedUnsentAndOnlySendItSends() async {
        let desk = FakeDesk()
        let writing = writer(desk, local: nil)
        let drafted = await writing.handle("come up with a reply for this")
        XCTAssertEqual(field(drafted, "status"), VoiceToolResult.Status.ok)
        XCTAssertEqual(desk.value, "Yes, see you at 5.\nI'll bring the notes.")
        XCTAssertTrue(field(drafted, "say")?.contains("Yes, see you at 5.") == true)
        XCTAssertFalse(field(drafted, "say")?.contains("bring the notes") == true)
        for said in ["yes", "okay", "open notes", "type it", "that looks good"] {
            _ = await writing.handle(said)
        }
        XCTAssertTrue(desk.sent.isEmpty)
        let sent = await writing.handle("send it")
        XCTAssertEqual(field(sent, "say"), "Sent.")
        XCTAssertEqual(desk.sent.map(\.text), ["Yes, see you at 5.\nI'll bring the notes."])
        XCTAssertNil(writing.pending)
    }

    func testSendItRefusesOnceTheDraftLeftTheField() async {
        let desk = FakeDesk()
        let writing = writer(desk, local: nil)
        _ = await writing.handle("come up with a reply for this")
        desk.value = ""
        let refused = await writing.handle("send it")
        XCTAssertEqual(field(refused, "status"), VoiceToolResult.Status.refused)
        desk.value = "Yes, see you at 5.\nI'll bring the notes."
        desk.pid = 99
        let otherApp = await writing.handle("send it")
        XCTAssertEqual(field(otherApp, "status"), VoiceToolResult.Status.refused)
        XCTAssertTrue(desk.sent.isEmpty)
    }

    func testDraftWithoutAReplyFieldWaitsToBePlacedBeforeSending() async {
        let desk = FakeDesk()
        desk.editable = false
        let writing = writer(desk, local: nil)
        let shown = await writing.handle("draft a reply to this")
        XCTAssertEqual(field(shown, "status"), VoiceToolResult.Status.question)
        XCTAssertTrue(desk.inserts.isEmpty)
        desk.editable = true
        let early = await writing.handle("send it")
        XCTAssertEqual(field(early, "status"), VoiceToolResult.Status.question)
        XCTAssertTrue(desk.sent.isEmpty)
        _ = await writing.handle("type it")
        XCTAssertEqual(desk.inserts.count, 1)
        _ = await writing.handle("send it")
        XCTAssertEqual(desk.sent.count, 1)
    }

    func testNothingToReplyToAsksWhichOne() async {
        let desk = FakeDesk()
        let payload = await writer(desk, local: nil, referent: nil).handle("come up with a reply for this")
        XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.question)
        XCTAssertEqual(desk.composed, 0)
    }

    func testPrivateTextIsNeverSentForADraft() async {
        let privateReferents = [
            WritingByInstruction.Referent(text: "hunter2", appName: "Safari", windowTitle: "Sign in", sensitive: true),
            WritingByInstruction.Referent(text: "Bank login: hunter2", appName: "1Password 8", windowTitle: "Vault",
                                          bundleID: "com.1password.1password"),
            WritingByInstruction.Referent(text: "recovery code 1234", appName: "Bitwarden", windowTitle: nil),
        ]
        for referent in privateReferents {
            let desk = FakeDesk()
            let payload = await writer(desk, local: nil, referent: referent).handle("come up with a reply for this")
            XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.refused, referent.text)
            XCTAssertEqual(desk.composed, 0, referent.text)
            XCTAssertTrue(desk.inserts.isEmpty, referent.text)
        }
    }

    func testCardNumbersAreMaskedBeforeDrafting() async {
        let desk = FakeDesk()
        let referent = WritingByInstruction.Referent(text: "Can you pay with 4111 1111 1111 1111 today?",
                                                     appName: "Messages", windowTitle: "Sam")
        _ = await writer(desk, local: nil, referent: referent).handle("come up with a reply for this")
        XCTAssertEqual(desk.composedFrom, ["Can you pay with [card number hidden] today?"])
    }

    func testAWindowChangeWhileWritingTypesNothing() async {
        let desk = FakeDesk()
        let drafting = writer(desk, local: nil)
        drafting.compose = { _ in desk.current = false; return "On my way." }
        let drafted = await drafting.handle("come up with a reply for this", isCurrent: { desk.current })
        XCTAssertEqual(field(drafted, "status"), VoiceToolResult.Status.refused)
        XCTAssertTrue(desk.inserts.isEmpty)
        XCTAssertEqual(drafting.pending, .draft(.init(text: "On my way.")))

        desk.current = true
        let typing = writer(desk, local: nil)
        typing.localTranscript = { desk.current = false; return "type this see you at five" }
        let typed = await typing.handle("type this see you at five", isCurrent: { desk.current })
        XCTAssertEqual(field(typed, "status"), VoiceToolResult.Status.refused)
        XCTAssertTrue(desk.inserts.isEmpty)
    }

    func testQuotedReplyWordsAreTypedNotDrafted() async {
        let desk = FakeDesk()
        let said = "type this \"please write a reply to this\""
        let payload = await writer(desk, local: said).handle(said)
        XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.ok)
        XCTAssertEqual(desk.inserts, ["please write a reply to this"])
        XCTAssertEqual(desk.composed, 0)
    }

    private func referent(_ source: DeicticReferent.Source, role: String, label: String) -> DeicticReferent {
        DeicticReferent(id: "axref:42:7:1", source: source, role: role, label: label, appName: "Mail",
                        windowTitle: "Inbox", pid: 42, windowID: 7, confidence: nil, element: nil)
    }

    func testThisResolvesThroughTheDeicticResolverFirst() async {
        let fallback = WritingByInstruction.Referent(text: "selected text", appName: nil, windowTitle: nil)
        var asked: [TimeInterval] = []
        let gaze = await WritingByInstruction.deicticReferent(
            wordTime: 12.5,
            resolve: { asked.append($0); return .resolved(self.referent(.gaze, role: "AXStaticText", label: "Are we still on for 5?")) },
            read: { _ in nil }, fallback: { fallback })
        XCTAssertEqual(asked, [12.5])
        XCTAssertEqual(gaze, .init(text: "Are we still on for 5?", appName: "Mail", windowTitle: "Inbox"))

        let readText = await WritingByInstruction.deicticReferent(
            wordTime: 1, resolve: { _ in .resolved(self.referent(.pointer, role: "AXGroup", label: "Message")) },
            read: { _ in "Lunch tomorrow?" }, fallback: { fallback })
        XCTAssertEqual(readText?.text, "Lunch tomorrow?")
    }

    func testReplyFieldsAndWhichOneFallBackToTheSelectionOrFocusedText() async {
        let fallback = WritingByInstruction.Referent(text: "selected text", appName: nil, windowTitle: nil)
        for resolution: DeicticResolution in [
            .whichOne,
            .resolved(referent(.focus, role: "AXTextArea", label: "Message body")),
            .resolved(referent(.gaze, role: "AXTextField", label: "Reply")),
            .resolved(referent(.pointer, role: "AXGroup", label: "")),
        ] {
            let found = await WritingByInstruction.deicticReferent(
                wordTime: 1, resolve: { _ in resolution }, read: { _ in nil }, fallback: { fallback })
            XCTAssertEqual(found, fallback, "\(resolution)")
        }
        let selected = await WritingByInstruction.deicticReferent(
            wordTime: 1, resolve: { _ in .resolved(self.referent(.selection, role: "AXTextArea", label: "")) },
            read: { _ in "the selected question" }, fallback: { fallback })
        XCTAssertEqual(selected?.text, "the selected question")
    }

    func testBrowserReplyFieldsFallBackLikeNativeOnes() async {
        let fallback = WritingByInstruction.Referent(text: "selected text", appName: nil, windowTitle: nil)
        for role in ["textarea", "input", "textbox", "searchbox", "combobox", "TextArea"] {
            let found = await WritingByInstruction.deicticReferent(
                wordTime: 1, resolve: { _ in .resolved(self.referent(.gaze, role: role, label: "Reply")) },
                read: { _ in nil }, fallback: { fallback })
            XCTAssertEqual(found, fallback, role)
        }
    }

    func testResolvedPrivateTextIsMarkedAndNeverDrafted() async {
        for (role, label) in [("AXSecureTextField", ""), ("AXTextField", "Password"), ("input", "One-time code")] {
            let found = await WritingByInstruction.deicticReferent(
                wordTime: 1, resolve: { _ in .resolved(self.referent(.selection, role: role, label: label)) },
                read: { _ in "hunter2" }, fallback: { nil })
            XCTAssertEqual(found?.sensitive, true, role)

            let desk = FakeDesk()
            let writing = writer(desk, local: nil)
            writing.referent = { _ in found }
            let payload = await writing.handle("come up with a reply for this")
            XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.refused, role)
            XCTAssertEqual(desk.composed, 0, role)
        }
        let message = await WritingByInstruction.deicticReferent(
            wordTime: 1, resolve: { _ in .resolved(self.referent(.gaze, role: "AXStaticText", label: "What's the door PIN?")) },
            read: { _ in nil }, fallback: { nil })
        XCTAssertEqual(message?.sensitive, false)
    }

    func testSendItWithoutADraftIsNotOurs() async {
        let payload = await writer(FakeDesk(), local: nil).handle("send it")
        XCTAssertNil(payload)
    }

    func testDraftRequestIsStrictAndStoresNothing() {
        let request = WritingByInstruction.composeRequest(for: Self.message)
        XCTAssertTrue(request.text.contains("Are we still on for 5?"))
        XCTAssertEqual(request.schema["required"], .array([.string("reply")]))
        XCTAssertEqual(TerraClient.body(for: request)["store"], .bool(false))
    }

    // MARK: - Gate and today's lane

    func testOffUnlessVoiceLive() async {
        let desk = FakeDesk()
        let writing = writer(desk, local: "type this hello", enabled: { false })
        for said in ["type this hello", "come up with a reply for this", "send it"] {
            let payload = await writing.handle(said)
            XCTAssertNil(payload, said)
        }
        XCTAssertTrue(desk.inserts.isEmpty)
        XCTAssertEqual(desk.composed, 0)
    }

    func testBeginVoiceTaskReachesWritingWithTheSpokenWords() async {
        let config = Config(defaults: UserDefaults(suiteName: "writing-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.handsFreeEnabled = false
        config.voiceLive = true
        let coordinator = VoiceTaskCoordinator(config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
        let desk = FakeDesk()
        coordinator.writingByInstruction = writer(desk, local: "type this see you at five",
                                                  enabled: { config.voiceLive })

        let typed = await coordinator.beginVoiceTask("type this see you at five", literalText: "this see you at five",
                                                     transcriptHint: "Type this: 'See you at five!'")
        XCTAssertEqual(field(typed, "status"), VoiceToolResult.Status.ok)
        XCTAssertEqual(desk.value, "See you at five!")

        coordinator.writingByInstruction = writer(desk, local: nil, enabled: { config.voiceLive })
        let asked = await coordinator.beginVoiceTask("type this Siobhán", transcriptHint: "type this Siobhán")
        XCTAssertEqual(field(asked, "status"), VoiceToolResult.Status.question)
        let confirmed = await coordinator.beginVoiceTask("type it", literalText: "it", transcriptHint: "type it")
        XCTAssertEqual(field(confirmed, "status"), VoiceToolResult.Status.ok)
        XCTAssertEqual(desk.value, "See you at five!Siobhán")
        XCTAssertTrue(coordinator.tasks.isEmpty)
    }

    func testBeginVoiceTaskRechecksAdmissionBeforeTyping() async {
        let config = Config(defaults: UserDefaults(suiteName: "writing-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.handsFreeEnabled = false
        config.voiceLive = true
        let coordinator = VoiceTaskCoordinator(config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
        let desk = FakeDesk()
        let writing = writer(desk, local: nil, enabled: { config.voiceLive })
        writing.compose = { _ in desk.current = false; return "On my way." }
        coordinator.writingByInstruction = writing

        let payload = await coordinator.beginVoiceTask("come up with a reply for this",
                                                       transcriptHint: "come up with a reply for this",
                                                       admissionIsCurrent: { desk.current })
        XCTAssertEqual(field(payload, "status"), VoiceToolResult.Status.refused)
        XCTAssertTrue(desk.inserts.isEmpty)
    }

    // MARK: - On-device transcription seams

    func testRecentSpeechKeepsOnlyTheLastTwentySeconds() {
        let ring = RecentSpeechAudio(isRecording: true)
        for _ in 0..<25 { ring.append(Data(count: 48_000)) }
        XCTAssertEqual(ring.snapshot().count, 20 * 48_000)
        ring.clear()
        XCTAssertTrue(ring.snapshot().isEmpty)
    }

    func testRecentSpeechKeepsNothingUntilVoiceLiveTurnsItOn() {
        let ring = RecentSpeechAudio()
        ring.append(Data(count: 48_000))
        XCTAssertTrue(ring.snapshot().isEmpty)
        ring.isRecording = true
        ring.append(Data(count: 48_000))
        XCTAssertEqual(ring.snapshot().count, 48_000)
        ring.isRecording = false
        XCTAssertTrue(ring.snapshot().isEmpty)
    }

    func testTranscriberAsksForPermissionOnceAndNeverWaitsOnIt() async {
        final class Asked: @unchecked Sendable { var count = 0 }
        let asked = Asked()
        var transcriber = LocalSpanTranscriber()
        transcriber.authorization = { .notDetermined }
        transcriber.requestAuthorization = { asked.count += 1 }
        let pending = await transcriber.transcribe(Data(count: 4_800))
        XCTAssertNil(pending)
        XCTAssertEqual(asked.count, 1)
        transcriber.authorization = { .denied }
        let denied = await transcriber.transcribe(Data(count: 4_800))
        XCTAssertNil(denied)
        XCTAssertEqual(asked.count, 1)
    }

    func testRealtimePCMConvertsToTheAnalyzerFormat() throws {
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(LocalSpanTranscriber.convert(Data(count: 48_000), to: target))
        XCTAssertEqual(buffer.format, target)
        XCTAssertEqual(Double(buffer.frameLength), 16_000, accuracy: 400)
    }
}

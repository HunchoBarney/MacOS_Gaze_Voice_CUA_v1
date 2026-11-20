import JarvisCore
import XCTest
@testable import Jarvis

/// Screen questions answered from the words in a window: the tool is on and
/// validated, the result carries the digest and the question, password
/// managers and thin windows get fixed lines, a named control maps back to
/// its frame, and secret fields labelled only by a placeholder stay hidden.
@MainActor
final class ScreenQuestionTests: XCTestCase {

    private func rect(_ y: CGFloat) -> CGRect { CGRect(x: 10, y: y, width: 200, height: 24) }

    private func digest(app: String = "Mail", bundleID: String? = "com.apple.mail",
                        _ children: [ScreenNode]) -> ScreenDigest {
        ScreenContext.digest(app: app, bundleID: bundleID, windowTitle: "Draft",
                             root: ScreenNode(role: "AXWindow", children: children))
    }

    private var mailDraft: ScreenDigest {
        digest([
            ScreenNode(role: "AXStaticText", value: "Hi Linda, the photos from Saturday are attached."),
            ScreenNode(role: "AXButton", description: "Send", frame: rect(10)),
            ScreenNode(role: "AXButton", description: "Send Later", frame: rect(40)),
            ScreenNode(role: "AXButton", description: "Attach", frame: rect(70)),
        ])
    }

    // MARK: - Tool catalog

    func testAskAboutScreenIsAvailableWithScopeEnum() throws {
        XCTAssertFalse(VoiceToolCatalog.unavailable.contains("ask_about_screen"))
        let tool = try XCTUnwrap(RealtimeVoiceClient.toolDefinitions.first { $0["name"] as? String == "ask_about_screen" })
        let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
        let scope = try XCTUnwrap((parameters["properties"] as? [String: Any])?["scope"] as? [String: Any])
        XCTAssertEqual(scope["enum"] as? [String], ["window", "screen"])
        XCTAssertEqual(parameters["required"] as? [String], ["question"])
        XCTAssertTrue(RealtimeVoiceClient.instructions.contains("Let me look."))
        XCTAssertTrue(RealtimeVoiceClient.instructions.contains("never claim to see pixels"))
    }

    func testAskAboutScreenArgumentsAreValidated() async throws {
        let text = "what does this button do"
        let session = LocalSpeechSession { _ in XCTFail("a screen question is remote") }
        let submitted = await session.submitTyped(text, now: 1)
        let admission = try XCTUnwrap(submitted)
        XCTAssertEqual(admission.route, .remote)
        func args(_ fields: [String: JSONValue]) throws -> String {
            String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)
        }
        for scope in ["window", "screen"] {
            XCTAssertNoThrow(try VoiceToolCatalog.validate("ask_about_screen",
                arguments: args(["question": .string(text), "scope": .string(scope)]),
                admission: admission, context: .init()), scope)
        }
        XCTAssertNoThrow(try VoiceToolCatalog.validate("ask_about_screen",
            arguments: args(["question": .string(text)]), admission: admission, context: .init()))
        for bad: [String: JSONValue] in [
            ["question": .string(text), "scope": .string("desktop")],
            ["question": .string("what's on the page")],
            ["question": .string(text), "picture": .bool(true)],
            ["scope": .string("window")],
        ] {
            XCTAssertThrowsError(try VoiceToolCatalog.validate("ask_about_screen", arguments: args(bad),
                                                               admission: admission, context: .init()), "\(bad)")
        }
    }

    // MARK: - Handler output

    func testWindowScopeSendsTheDigestAndQuestion() async throws {
        let reply = await ScreenQuestion.reply(question: "which button sends this?", scope: .window,
                                               focused: mailDraft, windows: [.init(app: "Safari", title: "News")])
        guard case .text(let text, let digest) = reply else { return XCTFail("\(reply)") }
        XCTAssertEqual(digest, mailDraft)
        XCTAssertTrue(text.hasPrefix("Question: which button sends this?"))
        XCTAssertTrue(text.contains("[e2] button \"Send\""))
        XCTAssertFalse(text.contains("Safari"), "window scope reads only the focused window")
        XCTAssertFalse(text.contains("y: 10"), "frames stay on the Mac")
    }

    func testScreenScopeListsEveryWindowPlusTheFocusedDigest() async throws {
        let windows: [ScreenQuestion.WindowTitle] = [.init(app: "Mail", title: "Draft"),
                                                     .init(app: "Safari", title: "Weather – Tuesday"),
                                                     .init(app: "1Password", title: "")]
        let reply = await ScreenQuestion.reply(question: "what's on my screen?", scope: .screen,
                                               focused: mailDraft, windows: windows)
        guard case .text(let text, _) = reply else { return XCTFail("\(reply)") }
        XCTAssertTrue(text.contains("- Safari: Weather – Tuesday"))
        XCTAssertTrue(text.contains("\n- 1Password\n"))
        XCTAssertTrue(text.contains("Focused window:\nApp: Mail"))
        XCTAssertTrue(text.contains("Hi Linda"))
    }

    func testScreenScopeIsBoundedByTheWindowCap() async throws {
        let many = (1...50).map { ScreenQuestion.WindowTitle(app: "App\($0)", title: "") }
        let reply = await ScreenQuestion.reply(question: "what's on my screen?", scope: .screen,
                                               focused: mailDraft, windows: many)
        guard case .text(let text, _) = reply else { return XCTFail("\(reply)") }
        XCTAssertTrue(text.contains("- App20\n"))
        XCTAssertFalse(text.contains("App21"))
    }

    func testPasswordManagerIsRefused() async {
        let vault = digest(app: "1Password", bundleID: "com.1password.1password", [
            ScreenNode(role: "AXStaticText", value: "bank: rose / hunter2"),
        ])
        let reply = await ScreenQuestion.reply(question: "what does this say?", scope: .window,
                                               focused: vault, windows: [])
        XCTAssertEqual(reply, .refused("That's a password manager, so I won't read it."))
    }

    func testUnreadableWindowGetsAFixedLine() async {
        let reply = await ScreenQuestion.reply(question: "what does this say?", scope: .window,
                                               focused: nil, windows: [])
        XCTAssertEqual(reply, .unavailable(ScreenQuestion.unreadable))
    }

    func testThinTextFallsBackToTheCantReadLine() async {
        let thinWeb = digest(app: "Safari", bundleID: "com.apple.Safari", [
            ScreenNode(role: "AXWebArea", url: "https://photos.example/1", children: [
                ScreenNode(role: "AXStaticText", value: "IMG_2041"),
            ]),
        ])
        let pictures = digest(app: "Preview", bundleID: "com.apple.Preview", [
            ScreenNode(role: "AXImage", description: "Beach"),
        ])
        for digest in [thinWeb, pictures, digest([])] {
            XCTAssertTrue(ScreenQuestion.needsPicture(digest))
            let reply = await ScreenQuestion.reply(question: "what is this?", scope: .window,
                                                   focused: digest, windows: [])
            XCTAssertEqual(reply, .unavailable("I can't read that part from text yet."))
        }
        let dialog = digest(app: "TextEdit", bundleID: "com.apple.TextEdit", [
            ScreenNode(role: "AXStaticText", value: "Save changes?"),
            ScreenNode(role: "AXButton", title: "Don't Save"), ScreenNode(role: "AXButton", title: "Save"),
        ])
        XCTAssertFalse(ScreenQuestion.needsPicture(dialog), "a short native dialog is readable text")
    }

    func testTextOutputIsSaylessJSONSoTheModelAnswers() throws {
        let output = ScreenQuestion.output("Question: q\nApp: Mail")
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(value["kind"]?.string, "screen_text")
        XCTAssertEqual(value["screen"]?.string, "Question: q\nApp: Mail")
        XCTAssertNil(RealtimeVoiceLane.deterministicSay(output), "the model must answer, not the host")
    }

    // MARK: - Glow on the named control

    func testAnswerNamingAControlMapsToItsFrame() {
        let draft = mailDraft
        XCTAssertEqual(ScreenQuestion.pointedRef(answer: "Press the Send button, top left.", in: draft), "e2")
        XCTAssertEqual(ScreenQuestion.pointedRef(answer: "Use Send Later to schedule it.", in: draft), "e3")
        XCTAssertEqual(draft.frame(ref: "e3"), rect(40))
        XCTAssertNil(ScreenQuestion.pointedRef(answer: "It says hi to Linda.", in: draft), "plain text never glows")
        XCTAssertNil(ScreenQuestion.pointedRef(answer: "Ask me again.", in: draft))
        let twins = digest([ScreenNode(role: "AXButton", title: "Reply", frame: rect(10)),
                            ScreenNode(role: "AXButton", title: "Reply", frame: rect(40))])
        XCTAssertNil(ScreenQuestion.pointedRef(answer: "Press Reply.", in: twins), "two Replies can't be told apart")
    }

    // MARK: - Gaze "what is this"

    func testGazeDescribeReadsTheSmallestElementThroughTheReader() {
        let draft = mailDraft
        XCTAssertEqual(ScreenQuestion.describe(at: CGPoint(x: 20, y: 50), in: draft), "That's a button, “Send Later”, in Mail.")
        XCTAssertEqual(ScreenQuestion.describe(at: CGPoint(x: 900, y: 900), in: draft), "That's Mail's “Draft” window.")
        let vault = digest(app: "Passwords", bundleID: "com.apple.Passwords", [])
        XCTAssertEqual(ScreenQuestion.describe(at: .zero, in: vault), ScreenQuestion.vaultRefusal)
        let card = digest([ScreenNode(role: "AXTextField", value: "123", placeholder: "CVV", frame: rect(10))])
        let said = ScreenQuestion.describe(at: CGPoint(x: 20, y: 20), in: card)
        XCTAssertFalse(said.contains("123"), said)
    }

    // MARK: - Placeholder redaction (JARA-38)

    func testSecretFieldsLabelledOnlyByPlaceholderAreRedacted() {
        for (index, placeholder) in ["CVV", "Security code", "One-time code"].enumerated() {
            let frame = rect(CGFloat(index) * 30)
            let read = digest(app: "Safari", bundleID: "com.apple.Safari", [
                ScreenNode(role: "AXTextField", title: "Payment", value: "481516", placeholder: placeholder, frame: frame),
            ])
            XCTAssertEqual(read.redactions, [frame], placeholder)
            XCTAssertFalse(read.rendered.contains("481516"), placeholder)
        }
        let search = digest(app: "Safari", bundleID: "com.apple.Safari", [
            ScreenNode(role: "AXTextField", value: "weather", placeholder: "Search", frame: rect(10)),
        ])
        XCTAssertTrue(search.redactions.isEmpty)
        XCTAssertTrue(search.rendered.contains("[e1] text field \"Search: weather\""))
    }

    func testPlaceholderSecretInsideAControlStillRedacts() {
        let read = digest(app: "Safari", bundleID: nil, [
            ScreenNode(role: "AXButton", title: "Verify", children: [
                ScreenNode(role: "AXTextField", placeholder: "One-time code", frame: rect(90)),
            ]),
        ])
        XCTAssertEqual(read.redactions, [rect(90)])
    }

    func testSensitiveFieldChecksEveryName() {
        XCTAssertTrue(SensitiveContent.isSensitiveField(title: nil, description: nil, placeholder: "CVV"))
        XCTAssertTrue(SensitiveContent.isSensitiveField(title: "Card", description: "Security code", placeholder: nil))
        XCTAssertFalse(SensitiveContent.isSensitiveField(title: "Name", description: nil, placeholder: "Jane Appleseed"))
    }

    // MARK: - Provider error text (JARA-38)

    func testProviderErrorTextNeverCarriesAKey() {
        let masked = "Incorrect API key provided: sk-proj-abc1****************wxyz. You can find your API key at…"
        XCTAssertEqual(RealtimeVoiceClient.scrubbed(masked),
                       "Incorrect API key provided: [key hidden]. You can find your API key at…")
        let frame = #"{"type":"error","error":{"type":"invalid_request_error","code":"session_expired","message":"Bad key sk-abc***xyz"}}"#
        guard case .failure(let text)? = RealtimeVoiceClient.decode(frame).first else { return XCTFail("expected failure") }
        XCTAssertFalse(text.contains("sk-"), text)
    }
}

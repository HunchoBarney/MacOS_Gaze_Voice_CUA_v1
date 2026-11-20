import XCTest
@testable import Jarvis

/// Voice-only control with eye tracking off: the spoken commands that
/// replace pointing, the replies, the listening-mode seam and the
/// on-screen indicator's states.
@MainActor
final class VoiceFirstTests: XCTestCase {

    // MARK: - Commands

    func testClickAndShowNameParse() {
        let cases: [(String, String, Bool)] = [
            ("click send", "send", true), ("click on send", "send", true),
            ("press the send button", "send button", true), ("tap reply all", "reply all", true),
            ("show me send", "send", false), ("point to the save link", "save link", false),
        ]
        for (phrase, name, clicks) in cases {
            guard let parsed = FastAction.parse(phrase) else {
                XCTFail("'\(phrase)' should parse"); continue
            }
            switch parsed.action.body {
            case .clickNamed(let got) where clicks: XCTAssertEqual(got, name, phrase)
            case .showNamed(let got) where !clicks: XCTAssertEqual(got, name, phrase)
            default: XCTFail("'\(phrase)' parsed to \(parsed.action.body)")
            }
        }
    }

    /// "show me Chrome" still brings Chrome forward when the Mac knows an
    /// app by that name; the speech session decides with the app list.
    func testShowMeNameParsesWithoutAppKnowledge() {
        guard let parsed = FastAction.parse("show me chrome"), case .showNamed("chrome") = parsed.action.body else {
            return XCTFail("parse alone can't know Chrome is an app")
        }
    }

    /// Pointing words and numbers aren't names: they stay with gaze and
    /// the numbered pick.
    func testDeicticAndNumbersAreNotNames() {
        for phrase in ["click this", "click that", "click it", "click here", "click 3", "click three"] {
            if let parsed = FastAction.parse(phrase), case .clickNamed = parsed.action.body {
                XCTFail("'\(phrase)' must not be a named click")
            }
        }
        guard let pick = FastAction.parse("click 2"), case .overlay(.clickIndex(2)) = pick.action.body else {
            return XCTFail("'click 2' picks numbered chip 2")
        }
    }

    // MARK: - Matching names

    private func candidate(_ label: String, x: Double, w: Double = 60, pressable: Bool = true)
        -> NamedTargetMatch.Candidate {
        .init(label: label, frame: CGRect(x: x, y: 10, width: w, height: 30), pressable: pressable)
    }

    func testExactNameBeatsLongerLabels() {
        let c = [candidate("Send later", x: 0), candidate("Send", x: 100), candidate("Resend", x: 200)]
        XCTAssertEqual(NamedTargetMatch.matches("send", in: c), [1])
    }

    func testPrefixThenWordMatch() {
        XCTAssertEqual(NamedTargetMatch.matches("reply", in: [candidate("Reply All", x: 0)]), [0])
        XCTAssertEqual(NamedTargetMatch.matches("all", in: [candidate("Reply All", x: 0)]), [0])
        XCTAssertEqual(NamedTargetMatch.matches("ply", in: [candidate("Reply All", x: 0)]), [])
    }

    /// The whole name wins; a trailing role word is dropped only when
    /// nothing matches it.
    func testRoleWordIsDroppedOnlyWhenTheWholeNameMisses() {
        let finder = [candidate("Open", x: 0), candidate("Open in New Tab", x: 100, w: 120)]
        XCTAssertEqual(NamedTargetMatch.matches("open in new tab", in: finder), [1])
        XCTAssertEqual(NamedTargetMatch.matches("settings tab", in: [candidate("Settings", x: 0)]), [0])
        XCTAssertEqual(NamedTargetMatch.matches("save button", in: [candidate("Save", x: 0)]), [0])
        XCTAssertEqual(NamedTargetMatch.matches("tab", in: [candidate("Settings", x: 0)]), [])
    }

    /// The front-window check for a name ending in an app accepts only an
    /// exact or starts-with label.
    func testStrictMatchIgnoresLabelsThatOnlyContainTheName() {
        let help = [candidate("How to save in Pages documents", x: 0, w: 200)]
        XCTAssertEqual(NamedTargetMatch.matches("save in pages", in: help), [0])
        XCTAssertEqual(NamedTargetMatch.matches("save in pages", in: help, anywhere: false), [])
        XCTAssertEqual(NamedTargetMatch.matches("save in pages",
                                                in: [candidate("Save in Pages…", x: 0)], anywhere: false), [0])
        XCTAssertEqual(NamedTargetMatch.matches("save in pages",
                                                in: [candidate("Save in Pages", x: 0)], anywhere: false), [0])
    }

    func testTwoButtonsWithTheSameNameAreAmbiguous() {
        let c = [candidate("Send", x: 0), candidate("Send", x: 300)]
        XCTAssertEqual(NamedTargetMatch.matches("Send!", in: c), [0, 1])
    }

    /// The text inside a button is the button, not a second match.
    func testTextInsideAButtonCollapsesIntoIt() {
        let c = [candidate("Send", x: 0, w: 100), candidate("Send", x: 20, w: 40, pressable: false)]
        XCTAssertEqual(NamedTargetMatch.matches("send", in: c), [0])
    }

    func testWhichOneQuestion() {
        XCTAssertEqual(DriveLoop.whichOneReply(label: "Send", count: 2),
                       "I can see two things called Send. One or two?")
        XCTAssertEqual(DriveLoop.whichOneReply(label: "Send", count: 3),
                       "I can see three things called Send. One, Two or three?")
        XCTAssertEqual(DriveLoop.whichOneReply(label: "Send", count: 9),
                       "I can see 9 things called Send. Say the number of the one you want.")
    }

    // MARK: - Show names

    func testNameChipsDropEmptyDuplicateAndLongLabels() {
        let button = CGRect(x: 0, y: 0, width: 100, height: 30)
        let chips = VoiceTaskCoordinator.nameChips([
            (button, "Send"),
            (CGRect(x: 20, y: 5, width: 40, height: 20), "Send"),
            (CGRect(x: 200, y: 0, width: 50, height: 30), "  "),
            (CGRect(x: 300, y: 0, width: 50, height: 30), String(repeating: "a", count: 40)),
        ])
        XCTAssertEqual(chips.map(\.label), ["Send", String(repeating: "a", count: 27) + "…"])
    }

    // MARK: - Replies

    func testEyesOffRepliesOfferSomethingToSay() {
        XCTAssertTrue(DriveLoop.eyesOffReply(.click).contains("“click Save”"))
        XCTAssertTrue(DriveLoop.eyesOffReply(.describe).contains("“show names”"))
        for verb in [FastAction.GazeVerb.click, .rightClick, .doubleClick, .describe] {
            XCTAssertFalse(DriveLoop.eyesOffReply(verb).lowercased().contains("turn eye tracking on"))
        }
    }

    func testHelpLeadsWithVoice() {
        let voice = VoiceTaskCoordinator.helpSummary(gaze: false)
        XCTAssertTrue(voice.contains("click Save"))
        XCTAssertTrue(voice.contains("show names"))
        XCTAssertFalse(voice.contains("click this"))
        XCTAssertTrue(VoiceTaskCoordinator.helpSummary(gaze: true).contains("click this"))
        XCTAssertFalse(VoiceTaskCoordinator.cheatSheet(gaze: false).joined().contains("click this"))
        XCTAssertTrue(VoiceTaskCoordinator.cheatSheet(gaze: true).joined().contains("click this"))
    }

    // MARK: - Listening modes

    func testWithoutWakeWordEngineStandbyIsNotOffered() {
        let policy = ListeningPolicy(wakeWordAvailable: false)
        XCTAssertEqual(policy.defaultMode, .pushToTalk)
        XCTAssertEqual(policy.offeredModes, [.pushToTalk, .conversation])
        XCTAssertEqual(policy.effective(.standby), .conversation)
        XCTAssertTrue(policy.streamsContinuously(.standby))
        XCTAssertFalse(policy.showsStandbyIntro)
    }

    func testWithWakeWordEngineStandbyIsTheDefault() {
        let policy = ListeningPolicy(wakeWordAvailable: true)
        XCTAssertEqual(policy.defaultMode, .standby)
        XCTAssertEqual(policy.offeredModes.first, .standby)
        XCTAssertEqual(policy.effective(.standby), .standby)
        XCTAssertFalse(policy.streamsContinuously(.standby))
        XCTAssertFalse(policy.streamsContinuously(.pushToTalk))
        XCTAssertTrue(policy.showsStandbyIntro)
    }

    func testNoWakeWordEngineShipsYet() {
        XCTAssertNil(ListeningPolicy.wakeWord)
        XCTAssertFalse(ListeningPolicy.current.wakeWordAvailable)
    }

    // MARK: - Permissions

    func testCameraIsRequiredOnlyWithEyeTracking() {
        XCTAssertFalse(Permission.required(gaze: false).contains(.camera))
        XCTAssertTrue(Permission.required(gaze: true).contains(.camera))
        XCTAssertEqual(Permission.required(gaze: false), [.microphone, .screenRecording, .accessibility])
    }

    // MARK: - Indicator

    func testIndicatorDropsOnlyForHearingWorkingAskingAndProblems() {
        func phase(_ capture: VoiceController.CaptureState = .idle,
                   _ status: VoiceController.Status = .idle,
                   turn: Bool = false, work: Bool = false, asks: Bool = false) -> IndicatorPhase {
            IndicatorPhase.resolve(capture: capture, status: status, conversationTurnOpen: turn,
                                   activeWork: work, pendingAsks: asks)
        }
        XCTAssertEqual(phase(), .hidden)
        XCTAssertEqual(phase(.idle, .done), .hidden, "outcomes are spoken, not shown")
        XCTAssertEqual(phase(.idle, .replied), .hidden)
        XCTAssertEqual(phase(.listening, .listening), .hearing)
        XCTAssertEqual(phase(turn: true), .hearing)
        XCTAssertEqual(phase(.idle, .thinking), .working)
        XCTAssertEqual(phase(.idle, .executing), .working)
        XCTAssertEqual(phase(work: true), .working)
        XCTAssertEqual(phase(.idle, .awaitingConfirm), .asking)
        XCTAssertEqual(phase(.idle, .awaitingAnswer("Which one?")), .asking)
        XCTAssertEqual(phase(work: true, asks: true), .asking)
        XCTAssertEqual(phase(.idle, .error("Microphone access is needed.")), .problem)
        XCTAssertEqual(phase(.listening, .listening, asks: true), .hearing, "talking wins while you talk")
        XCTAssertEqual(phase(.testingMicrophone, .testingMicrophone), .hidden)
    }
}

/// The stored listening mode and its legacy hands-free switch.
final class ListeningModeConfigTests: XCTestCase {
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func config(_ defaults: UserDefaults) -> Config {
        Config(defaults: defaults, keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
    }

    private func fresh() -> UserDefaults { UserDefaults(suiteName: "listening-\(UUID().uuidString)")! }

    func testDefaultsToHoldFnAndEyesOff() {
        let c = config(fresh())
        XCTAssertEqual(c.listeningMode, .pushToTalk)
        XCTAssertFalse(c.handsFreeEnabled)
        XCTAssertFalse(c.gazeTracking)
        XCTAssertFalse(c.firstRunCompleted)
    }

    func testLegacyHandsFreeOffMigratesToPushToTalk() {
        let defaults = fresh()
        defaults.set(false, forKey: "handsFreeEnabled")
        let c = config(defaults)
        XCTAssertEqual(c.listeningMode, .pushToTalk)
        XCTAssertFalse(c.handsFreeEnabled)
    }

    func testModeAndHandsFreeStayInStepAndPersist() {
        let defaults = fresh()
        let c = config(defaults)
        c.listeningMode = .pushToTalk
        XCTAssertFalse(c.handsFreeEnabled)
        c.handsFreeEnabled = true
        XCTAssertEqual(c.listeningMode, .conversation)
        c.handsFreeEnabled = false
        XCTAssertEqual(c.listeningMode, .pushToTalk)
        XCTAssertEqual(config(defaults).listeningMode, .pushToTalk)
        XCTAssertFalse(config(defaults).handsFreeEnabled)
    }

    /// A stored Standby choice listens all the time until an engine ships.
    func testStoredStandbyBehavesLikeListeningAllTheTime() {
        let defaults = fresh()
        defaults.set("standby", forKey: "listeningMode")
        let c = config(defaults)
        XCTAssertEqual(c.listeningMode, .standby)
        XCTAssertTrue(c.handsFreeEnabled)
    }
}

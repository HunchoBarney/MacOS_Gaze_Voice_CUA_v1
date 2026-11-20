import CoreGraphics
import XCTest
@testable import Jarvis
import JarvisCore

/// Recipes for the top guide tasks: conservative goal matching, hints
/// that steer only the step Jev chose, the fallback to the live tree when
/// a recipe's control is missing, the System Settings link on the
/// consented launch, and the note in the recipe's own words.
final class GuideRecipesTests: XCTestCase {
    static let window = CGRect(x: 0, y: 0, width: 900, height: 600)
    static let clock = GuideClock(now: { 100 }, sleep: { _ in })

    override func setUp() {
        usePrivateStandingGrants()
    }

    // MARK: - Matching

    func testGoalsMatchTheirRecipe() {
        let goals = [
            "attach a photo": "attach-photo",
            "send Linda a photo by email": "attach-photo",
            "save the photos from this email": "save-mail-photos",
            "save the attachments": "save-mail-photos",
            "put these pictures into Photos": "import-to-photos",
            "join the Zoom call": "join-call",
            "join my doctor\u{2019}s video appointment": "join-call",
            "printing this letter": "print",
            "make the writing bigger": "text-size",
            "make the pointer bigger": "pointer-size",
            "find my mouse pointer": "pointer-size",
            "fix the Wi-Fi": "wifi",
            "the internet isn't working": "wifi",
            "update my Mac": "updates",
            "get out of full screen": "exit-full-screen",
            "the menu bar is gone": "exit-full-screen",
            "find the form I downloaded": "find-download",
        ]
        for (goal, id) in goals {
            XCTAssertEqual(Recipe.match(goal)?.id, id, goal)
        }
    }

    func testUnmatchedAndAmbiguousGoalsRunPlainGuideMode() {
        for goal in ["send Linda a photo", "search the internet for recipes", "make it full screen",
                     "fix the printer", "update my apps", "make the text on this page bigger",
                     "reply to an email", "print the photo from this email and save it"] {
            XCTAssertNil(Recipe.match(goal), goal)
        }
        XCTAssertTrue(Recipe.printing.matches("print the photo from this email and save it"))
        XCTAssertTrue(Recipe.saveMailPhotos.matches("print the photo from this email and save it"),
                      "two recipes match, so neither is used")
    }

    func testNearMissGoalsDoNotStartASettingsOrKeyRecipe() {
        for goal in ["connect my wireless headphones", "my wireless keyboard isn\u{2019}t working",
                     "what\u{2019}s my wifi password", "share the wifi password with my daughter",
                     "I can\u{2019}t connect to the network printer", "the network drive won\u{2019}t connect",
                     "update my Apple ID password", "update my Apple Music subscription", "update the system font",
                     "send a text with a big picture", "text my son a large photo", "print screen",
                     "my mouse battery is low", "I lost my mouse connection", "I can\u{2019}t see the arrow keys",
                     "make the video full screen", "full screen my video"] {
            XCTAssertNil(Recipe.match(goal), goal)
        }
        for (goal, id) in ["turn the wifi off and on": "wifi", "I\u{2019}m stuck in full screen": "exit-full-screen",
                           "leave full screen": "exit-full-screen", "install the macOS update": "updates",
                           "I can\u{2019}t see my mouse": "pointer-size"] {
            XCTAssertEqual(Recipe.match(goal)?.id, id, goal)
        }
    }

    func testEveryRecipeIsShortAndHandWorded() {
        XCTAssertEqual(Set(Recipe.all.map(\.id)).count, Recipe.all.count)
        for recipe in Recipe.all {
            XCTAssertTrue(recipe.title.hasPrefix("How to "), recipe.id)
            XCTAssertFalse(recipe.steps.isEmpty, recipe.id)
            XCTAssertLessThanOrEqual(recipe.hints.count, 4, recipe.id)
            XCTAssertTrue((2...6).contains(recipe.note.count), recipe.id)
            XCTAssertTrue(recipe.note.allSatisfy { $0.hasSuffix(".") }, recipe.id)
            XCTAssertTrue(recipe.hints.allSatisfy { !($0.control ?? "").isEmpty }, recipe.id)
            if let link = recipe.link {
                XCTAssertTrue(SettingsLinks.all.contains(link), recipe.id)
                XCTAssertEqual(recipe.app, SettingsLinks.appBundle, recipe.id)
            } else {
                XCTAssertTrue(recipe.menuSteps.isEmpty, recipe.id)
            }
        }
        XCTAssertEqual(Set(Recipe.all.compactMap(\.link)), Set(SettingsLinks.all),
                       "every settings link has a recipe that uses it")
    }

    // MARK: - Hints steer only the chosen step

    private func element(_ label: String, role: String = "AXButton") -> GuideElement {
        GuideElement(role: role, label: label, frame: CGRect(x: 800, y: 20, width: 40, height: 30))
    }

    func testHintAppliesOnlyToTheControlJevChose() async {
        let attach = GuideSession(goal: "attach a photo", recipe: .attachPhoto, clock: Self.clock, present: { _ in })
        let paperclip = await attach.hint(for: .element(element("Attach")))
        XCTAssertEqual(paperclip?.describe, "the paperclip")
        let missing = await attach.hint(for: .element(element("Format")))
        XCTAssertNil(missing)
        let step = StepPhrasing.step(number: 1, action: .element(element("Attach")), window: Self.window,
                                     scene: [], hint: paperclip)
        XCTAssertEqual(step.instruction, "Click the paperclip, at the top of your message, on the right.")

        let join = GuideSession(goal: "join the call", recipe: .joinCall, clock: Self.clock, present: { _ in })
        let exact = await join.hint(for: .element(element("Join")))
        XCTAssertEqual(exact?.control, "Join", "the same words beat a label that only contains them")
        let audio = await join.hint(for: .element(element("Join with Computer Audio")))
        XCTAssertEqual(audio?.control, "Join with Computer Audio")

        let print = GuideSession(goal: "print this", recipe: .printing, clock: Self.clock, present: { _ in })
        let chord = await print.hint(for: .key("command+p"))
        XCTAssertEqual(chord?.control, "cmd+p")
        let full = GuideSession(goal: "leave full screen", recipe: .exitFullScreen, clock: Self.clock, present: { _ in })
        let menu = await full.hint(for: .menu(["View", "Exit Full Screen"]))
        XCTAssertEqual(menu?.control, "Exit Full Screen")
        let scroll = await full.hint(for: .scroll("down"))
        XCTAssertNil(scroll)
    }

    func testRecipeNamesTheEffectOfPressesTheConsequenceWordsMiss() {
        let update = Recipe.updates.steps[0]
        let step = StepPhrasing.step(number: 3, action: .element(element("Update Now")), window: Self.window,
                                     scene: [], hint: update)
        XCTAssertNil(step.consequence)
        XCTAssertEqual(StepPhrasing.opening(step, slow: false),
                       "This one installs the update and restarts your Mac. Click the Update Now button when you're ready.")
        let plain = StepPhrasing.step(number: 3, action: .element(element("Update Now")), window: Self.window,
                                      scene: [], hint: nil)
        XCTAssertNil(plain.consequenceLine, "without the recipe the step reads as before")
    }

    func testHintContextTellsJevTheRecipeAndTheLink() {
        let session = GuideSession(goal: "make the text bigger", recipe: .textSize, clock: Self.clock,
                                   linkProblem: { _ in nil }, present: { _ in })
        XCTAssertEqual(session.hintContext, """
            Recipe: How to make the text bigger on your Mac. System Settings was asked to open \
            Accessibility, Display, Text size; if that page is showing, skip the steps that get there.
            Guide steps: 1. Accessibility; 2. Display; 3. Text size
            """)
        XCTAssertNil(GuideSession(goal: "anything", clock: Self.clock, present: { _ in }).hintContext)
    }

    // MARK: - The note

    func testRecipeFeedsTheNoteItsOwnWording() {
        let note = GuideNote(recipe: .attachPhoto)
        XCTAssertEqual(note.text, """
            How to attach a photo to an email
            1. Open your new message in Mail.
            2. Click the paperclip at the top of the message.
            3. On the left of the panel that opens, click Photos.
            4. Click the photo you want.
            5. Click Choose File. The photo appears in your message.
            """)
        let session = GuideSession(goal: "attach a photo", recipe: .attachPhoto, clock: Self.clock, present: { _ in })
        XCTAssertEqual(session.recipe.map(GuideNote.init(recipe:)), note)
    }

    // MARK: - DriveLoop: the link and the live-tree fallback

    final class SettingsDriver: @unchecked Sendable {
        private let lock = NSLock()
        private var launchArgs: [[String: JSONValue]] = []
        private var didClick = false
        var refuseLinks = false
        var labels = ["Display", "Text size"]
        var launches: [[String: JSONValue]] { lock.lock(); defer { lock.unlock() }; return launchArgs }
        var clicked: Bool {
            get { lock.lock(); defer { lock.unlock() }; return didClick }
            set { lock.lock(); didClick = newValue; lock.unlock() }
        }

        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("System Settings"),
                                                          "bundle_id": .string(SettingsLinks.appBundle),
                                                          "pid": .number(77)])])])
            case "launch_app":
                lock.lock(); launchArgs.append(args); lock.unlock()
                if refuseLinks, args["urls"] != nil {
                    throw DriverConnectionError.toolRefused(tool: "launch_app", code: "open_failed",
                                                            detail: "the URL could not be opened")
                }
                return .object(["pid": .number(77), "bundle_id": .string(SettingsLinks.appBundle),
                                "name": .string("System Settings"),
                                "windows": .array([.object(["window_id": .number(7), "pid": .number(77),
                                                            "title": .string("Accessibility")])])])
            case "get_window_state":
                var rows = labels.enumerated().map { index, label in
                    GuideModeTests.Driver.row(index + 3, label: label, x: 300 + Double(index) * 200)
                }
                if clicked { rows.append(GuideModeTests.Driver.row(9, role: "AXStaticText", label: "Larger", x: 300)) }
                return .object(["window_title": .string("Accessibility"), "elements": .array(rows)])
            default:
                return .object(["effect": .string("confirmed")])
            }
        }
    }

    final class Holder: @unchecked Sendable { var session: GuideSession? }

    private func walkthrough(_ driver: SettingsDriver, pick: String = "e4",
                             linkProblem: @escaping (SettingsLink) -> String? = { _ in nil })
        async -> (DriveResult, GuideModeTests.Recorder) {
        let holder = Holder()
        let recorder = GuideModeTests.Recorder()
        let session = GuideSession(goal: "make the text bigger", recipe: .textSize, clock: Self.clock,
                                   linkProblem: linkProblem, present: { effect in
            recorder.add(effect)
            guard case .point(let step) = effect, let frame = step.target?.frame else { return }
            driver.clicked = true
            let click = UserAction(kind: .click(CGPoint(x: frame.midX, y: frame.midY)), pid: 77,
                                   element: step.target, at: 100)
            Task { await holder.session?.send(.action(click)) }
        })
        holder.session = session
        var picks = [pick, "done", "done"]
        let loop = DriveLoop(call: { tool, args in try driver.call(tool, args) },
                             choose: { _, _ in picks.isEmpty ? nil : DriveLoop.JevChoice(id: picks.removeFirst()) },
                             ask: nil, granted: { true },
                             windowControlButtons: { _ in [] }, windowControlPress: { _, _ in false },
                             frontmostBundleID: { nil }, frontmostPID: { 77 }, frontmostWindowID: { 7 },
                             resurrector: SessionResurrector(), nativeReadOnly: { _, _ in nil },
                             guide: session)
        let result = await loop.run(DriveTask(goal: "make the text bigger", application: SettingsLinks.appBundle,
                                              successContains: ["Larger"], foreground: true),
                                    session: "t")
        return (result, recorder)
    }

    private func pointedSteps(_ recorder: GuideModeTests.Recorder) -> [GuideStep] {
        recorder.effects.compactMap { if case .point(let step) = $0 { return step }; return nil }
    }

    func testSettingsLinkRidesTheConsentedLaunch() async {
        let driver = SettingsDriver()
        let (result, recorder) = await walkthrough(driver)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.launches.count, 1)
        XCTAssertEqual(driver.launches.first?["urls"],
                       .array([.string("x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FONT_SIZE")]))
        let step = pointedSteps(recorder).first
        XCTAssertEqual(step?.target?.label, "Text size")
        XCTAssertEqual(step?.detail, "It's under Text, with a small arrow on its right.", "the recipe's hint")
    }

    func testRefusedLinkOpensSettingsWithoutItAndTheMenuStepsCarryOn() async {
        let driver = SettingsDriver()
        driver.refuseLinks = true
        driver.labels = ["Accessibility", "Display"]
        let (result, recorder) = await walkthrough(driver)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.launches.count, 2)
        XCTAssertNotNil(driver.launches.first?["urls"])
        XCTAssertNil(driver.launches.last?["urls"], "the retry opens Settings without the link")
        let step = pointedSteps(recorder).first
        XCTAssertEqual(step?.target?.label, "Display")
        XCTAssertEqual(step?.detail, "It's under Vision, with a picture of a screen.", "the menu step's hint")
    }

    func testLinkThatDoesNotResolveIsNeverSent() async {
        let driver = SettingsDriver()
        let (result, _) = await walkthrough(driver, linkProblem: { _ in "anchor missing" })
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.launches.count, 1)
        XCTAssertNil(driver.launches.first?["urls"])
    }

    func testMissingControlFallsBackToTheLiveTree() async {
        let driver = SettingsDriver()
        driver.labels = ["Display", "Bigger Text"]
        let (result, recorder) = await walkthrough(driver)
        XCTAssertEqual(result.status, .done)
        let step = pointedSteps(recorder).first
        XCTAssertEqual(step?.target?.label, "Bigger Text", "Jev's choice from the live tree")
        XCTAssertEqual(step?.name, "the Bigger Text button")
        XCTAssertEqual(step?.detail.hasPrefix("Look for the button that says Bigger Text"), true,
                       "no hint names it, so the words are plain guide mode's")
        XCTAssertEqual(recorder.lines.last, "That's it.")
    }
}

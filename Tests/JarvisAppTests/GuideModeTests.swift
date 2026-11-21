import CoreGraphics
import XCTest
@testable import Jarvis
import JarvisCore

/// Guide mode ("show me how"): the step words, the point → wait → verify
/// state machine on an injected clock with synthetic clicks, the mode
/// flips, and the show path through DriveLoop with a synthetic tree.
final class GuideModeTests: XCTestCase {
    static let window = CGRect(x: 0, y: 0, width: 900, height: 600)
    static let attach = GuideElement(role: "AXButton", label: "Attach",
                                     frame: CGRect(x: 800, y: 20, width: 40, height: 30))
    static let format = GuideElement(role: "AXButton", label: "Format",
                                     frame: CGRect(x: 740, y: 20, width: 50, height: 30))
    static let body = GuideElement(role: "AXTextArea", label: "Message", value: "",
                                   frame: CGRect(x: 20, y: 120, width: 860, height: 440))
    static let trash = GuideElement(role: "AXButton", label: "Delete",
                                    frame: CGRect(x: 20, y: 20, width: 40, height: 30))

    override func setUp() {
        usePrivateStandingGrants()
    }

    private func scene(_ elements: [GuideElement] = [attach, format, body], pid: Int = 42,
                       windowID: Int = 7, app: String? = "Mail") -> GuideScene {
        GuideScene(pid: pid, windowID: windowID, appName: app, windowTitle: "New Message",
                   windowFrame: Self.window, elements: elements)
    }

    private func step(_ target: GuideElement = attach, number: Int = 1, hint: GuideHint? = nil) -> GuideStep {
        StepPhrasing.step(number: number, action: .element(target), window: Self.window,
                          scene: [Self.attach, Self.format, Self.body], hint: hint)
    }

    private func click(_ element: GuideElement, at time: TimeInterval = 101) -> UserAction {
        UserAction(kind: .click(CGPoint(x: element.frame!.midX, y: element.frame!.midY)),
                   pid: 42, element: element, at: time)
    }

    private func judge(_ action: UserAction, step: GuideStep? = nil, after: GuideScene,
                       detourOpen: Bool = false) -> GuideVerdict {
        GuideMachine.judge(action, step: step ?? self.step(), baseline: scene(), before: scene(),
                           after: after, detourOpen: detourOpen)
    }

    private func says(_ effects: [GuideEffect]) -> [String] {
        effects.compactMap { if case .say(let line) = $0 { return line }; return nil }
    }

    // MARK: - Step phrasing

    func testInstructionSaysWhereTheControlIs() {
        XCTAssertEqual(step().instruction, "Click the Attach button, at the top of the window, on the right.")
        let hinted = step(hint: GuideHint(describe: "the paperclip", windowNoun: "your message"))
        XCTAssertEqual(hinted.instruction, "Click the paperclip, at the top of your message, on the right.")
        XCTAssertEqual(StepPhrasing.opening(hinted, slow: false),
                       "Okay, one step at a time. First, click the paperclip, at the top of your message, on the right. It's glowing.")
        XCTAssertEqual(step().detail,
                       "Look for the button that says Attach, at the top of the window, on the right, next to the Format button.")
        XCTAssertEqual(StepPhrasing.opening(step(number: 2), slow: false),
                       "Now click the Attach button, at the top of the window, on the right.")
        XCTAssertEqual(step(Self.body).instruction, "Click in the Message box, in the middle of the window.")
        XCTAssertTrue(step().slow.hasPrefix("Take your time. Look at the top of the window, on the right."))
    }

    func testKeyMenuAndTypingSteps() {
        func instruction(_ action: GuideAction) -> String {
            StepPhrasing.step(number: 2, action: action, window: Self.window, scene: [], hint: nil).instruction
        }
        XCTAssertEqual(instruction(.key("escape")), "Press the Escape key, at the top left of your keyboard.")
        XCTAssertEqual(instruction(.key("cmd+z")), "Hold Command and press Z.")
        XCTAssertEqual(instruction(.menu(["File", "New Message"])),
                       "Click File, at the top of the screen, then click New Message.")
        let typing = StepPhrasing.step(number: 1, action: .element(Self.body, typing: "Hello"),
                                       window: Self.window, scene: [], hint: nil)
        XCTAssertEqual(typing.instruction, "Click in the Message box, in the middle of the window, and type \u{201C}Hello\u{201D}.")
        XCTAssertEqual(typing.expect, .appears("Hello"))
    }

    func testConsequentialStepNamesItsEffectFirst() {
        let send = GuideElement(role: "AXButton", label: "Send", frame: CGRect(x: 20, y: 20, width: 40, height: 30))
        let plain = step(send)
        XCTAssertEqual(plain.consequence, .send)
        XCTAssertEqual(StepPhrasing.opening(plain, slow: false),
                       "This one sends it. Click the Send button when you're ready.")
        let hinted = step(send, number: 4, hint: GuideHint(describe: "Send", effect: "sends it to Linda"))
        XCTAssertEqual(StepPhrasing.opening(hinted, slow: false),
                       "This one sends it to Linda. Click Send when you're ready.")
        XCTAssertNil(step().consequenceLine)
    }

    // MARK: - Verify and wrong clicks

    func testRightClickVerifiesAndPraises() {
        let sheet = GuideElement(role: "AXSheet", label: "Choose a file")
        let verdict = judge(click(Self.attach), after: scene([Self.attach, Self.format, Self.body, sheet]))
        XCTAssertEqual(verdict, .success(rebind: false))
        var machine = GuideMachine(step: step(), at: 100)
        let outcome = machine.judged(verdict, at: 101)
        XCTAssertEqual(says(outcome.effects), ["That's it."])
        XCTAssertEqual(outcome.transition, .advance(rebind: false))
    }

    func testWrongClickWithNothingChangedRepoints() {
        let verdict = judge(click(Self.format), after: scene())
        XCTAssertEqual(verdict, .nothingChanged(onTarget: false))
        var machine = GuideMachine(step: step(hint: GuideHint(describe: "the paperclip")), at: 100)
        let outcome = machine.judged(verdict, at: 101)
        XCTAssertEqual(outcome.effects, [.pulse(Self.attach.frame!), .say("That's okay. It's this one, the paperclip.")])
        XCTAssertNil(outcome.transition)
        XCTAssertEqual(machine.misses, 1)
    }

    func testWrongClickIntoAReversibleDetourOffersToCloseIt() {
        let menu = [GuideElement(role: "AXMenu", label: "Format"), GuideElement(role: "AXMenuItem", label: "Bold")]
        let opened = scene([Self.attach, Self.format, Self.body] + menu)
        let verdict = judge(click(Self.format), after: opened)
        XCTAssertEqual(verdict, .detour("the Format menu"))
        var machine = GuideMachine(step: step(), at: 100)
        XCTAssertEqual(says(machine.judged(verdict, at: 101).effects),
                       ["That opened the Format menu. Let's close it: press Escape, or say \u{201C}close it\u{201D}."])
        XCTAssertTrue(machine.detourOpen)
        let close = machine.heard(.closeIt, previous: nil, slow: false, at: 102)
        XCTAssertEqual(close.transition, .press(.escape))
        let after = machine.pressed(.escape, before: opened, after: scene(), baseline: scene(), at: 103)
        XCTAssertEqual(says(after), ["That's it. Now the Attach button."])
        XCTAssertFalse(machine.detourOpen)
        let closedByHand = UserAction(kind: .menuClosed, pid: 42, element: nil, at: 104)
        XCTAssertEqual(GuideMachine.judge(closedByHand, step: step(), baseline: scene(), before: opened,
                                          after: scene(), detourOpen: true), .detourClosed)
    }

    func testWrongClickWithAConsequenceExplainsAndOffersUndo() {
        let verdict = judge(click(Self.trash), after: scene([Self.attach, Self.format]))
        XCTAssertEqual(verdict, .consequential(.delete, label: "Delete", undoSend: false))
        var machine = GuideMachine(step: step(), at: 100)
        XCTAssertEqual(says(machine.judged(verdict, at: 101).effects),
                       ["That pressed Delete, which deletes. Say \u{201C}undo\u{201D} and I'll bring it back."])
        XCTAssertEqual(machine.heard(.undo, previous: nil, slow: false, at: 102).transition, .press(.undo))
        XCTAssertEqual(says(machine.pressed(.undo, before: scene([Self.attach]), after: scene(),
                                           baseline: scene(), at: 103)),
                       ["I undid it. Now, click the Attach button, at the top of the window, on the right."])

        let send = GuideElement(role: "AXButton", label: "Send", frame: CGRect(x: 60, y: 20, width: 40, height: 30))
        let undoSend = GuideElement(role: "AXButton", label: "Undo Send")
        XCTAssertEqual(judge(click(send), after: scene([Self.attach, undoSend])),
                       .consequential(.send, label: "Send", undoSend: true))
    }

    func testGoingSomewhereNewOnPurposeReplans() {
        let photos = scene([GuideElement(role: "AXButton", label: "Library")], pid: 77, windowID: 9, app: "Photos")
        let verdict = judge(click(GuideElement(role: "AXButton", label: "Library",
                                               frame: CGRect(x: 5, y: 5, width: 10, height: 10))), after: photos)
        XCTAssertEqual(verdict, .wentElsewhere("Photos", rebind: true))
        var machine = GuideMachine(step: step(), at: 100)
        let outcome = machine.judged(verdict, at: 101)
        XCTAssertEqual(says(outcome.effects), ["We're in Photos now. That's fine, let's carry on from here."])
        XCTAssertEqual(outcome.transition, .replan(rebind: true))
        let mailboxes = GuideElement(role: "AXButton", label: "Mailboxes",
                                     frame: CGRect(x: 100, y: 20, width: 60, height: 30))
        let reworked = scene([mailboxes, GuideElement(role: "AXStaticText", label: "Inbox")])
        XCTAssertEqual(judge(click(mailboxes), after: reworked), .wentElsewhere(nil, rebind: false))
    }

    func testThreeMissesOfferToDoTheStep() {
        var machine = GuideMachine(step: step(), at: 100)
        XCTAssertFalse(says(machine.judged(.nothingChanged(onTarget: false), at: 101).effects)
            .contains(GuideMachine.missOfferLine))
        XCTAssertFalse(says(machine.judged(.nothingChanged(onTarget: false), at: 102).effects)
            .contains(GuideMachine.missOfferLine))
        XCTAssertEqual(says(machine.judged(.nothingChanged(onTarget: false), at: 103).effects).last,
                       GuideMachine.missOfferLine)
        XCTAssertTrue(machine.offerPending)
        XCTAssertEqual(machine.heard(.yes, previous: nil, slow: false, at: 104).transition, .act)
        XCTAssertFalse(machine.offerPending)
    }

    func testTypingIntoTheTargetIsProgressNotAMiss() {
        let typing = StepPhrasing.step(number: 1, action: .element(Self.body, typing: "Hello"),
                                       window: Self.window, scene: [], hint: nil)
        XCTAssertEqual(judge(click(Self.body), step: typing, after: scene()), .typing)
        var partial = Self.body
        partial.value = "Hel"
        let keystroke = UserAction(kind: .valueChanged, pid: 42, element: Self.body, at: 101)
        let verdict = judge(keystroke, step: typing, after: scene([Self.attach, Self.format, partial]))
        XCTAssertEqual(verdict, .typing)
        var machine = GuideMachine(step: typing, at: 100)
        XCTAssertEqual(machine.judged(verdict, at: 108).effects, [])
        XCTAssertEqual(machine.misses, 0)
        XCTAssertEqual(machine.tick(at: 117), [], "typing counts as activity for patience")
        var done = Self.body
        done.value = "Hello"
        XCTAssertEqual(judge(keystroke, step: typing, after: scene([Self.attach, Self.format, done])),
                       .success(rebind: false))
    }

    // MARK: - Patience

    func testPatienceRepeatsWithDetailThenOffersAndNeverAThirdTime() {
        var machine = GuideMachine(step: step(), at: 100)
        XCTAssertEqual(machine.tick(at: 109.9), [])
        XCTAssertEqual(machine.tick(at: 110), [.pulse(Self.attach.frame!), .say(step().detail)])
        XCTAssertEqual(machine.tick(at: 124.9), [])
        XCTAssertEqual(machine.tick(at: 125), [.say(GuideMachine.offerLine)])
        XCTAssertTrue(machine.offerPending)
        for later in [130.0, 200, 1000, 10000] { XCTAssertEqual(machine.tick(at: later), []) }
    }

    func testPatienceCountsFromTheLastActionAndNeverRepeatsTheOffer() {
        var machine = GuideMachine(step: step(), at: 100)
        _ = machine.judged(.nothingChanged(onTarget: false), at: 108)
        XCTAssertEqual(machine.tick(at: 117), [])
        XCTAssertEqual(says(machine.tick(at: 118)), [step().detail])
        _ = machine.judged(.nothingChanged(onTarget: false), at: 119)
        _ = machine.judged(.nothingChanged(onTarget: false), at: 120)
        XCTAssertTrue(machine.offered)
        XCTAssertEqual(machine.tick(at: 200), [], "the miss offer already went; no second offer")
    }

    // MARK: - The session: synthetic clicks and mode flips

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GuideEffect] = []
        func add(_ effect: GuideEffect) { lock.lock(); stored.append(effect); lock.unlock() }
        var effects: [GuideEffect] { lock.lock(); defer { lock.unlock() }; return stored }
        var lines: [String] { effects.compactMap { if case .say(let s) = $0 { return s }; return nil } }
    }

    final class SceneBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: GuideScene
        init(_ scene: GuideScene) { current = scene }
        func set(_ scene: GuideScene) { lock.lock(); current = scene; lock.unlock() }
        var scene: GuideScene { lock.lock(); defer { lock.unlock() }; return current }
    }

    private static let clock = GuideClock(now: { 100 }, sleep: { _ in })

    private func pointed(_ session: GuideSession) async {
        for _ in 0..<10_000 {
            if await session.currentStep != nil { return }
            await Task.yield()
        }
        XCTFail("the step was never pointed")
    }

    func testSyntheticClickOnTheGlowingControlAdvances() async {
        let recorder = Recorder()
        let screen = SceneBox(scene())
        let session = GuideSession(goal: "attach a photo", clock: Self.clock, present: { recorder.add($0) })
        let pending = Task { await session.perform(.element(Self.attach), observe: { screen.scene }) }
        await pointed(session)
        await session.send(.action(click(Self.format, at: 100)))
        await session.send(.action(click(Self.attach, at: 100)))
        let wait = Task {
            for _ in 0..<10_000 {
                if recorder.lines.contains("That's okay. It's this one, the Attach button.") { return }
                await Task.yield()
            }
        }
        await wait.value
        screen.set(scene([Self.attach, Self.format, Self.body, GuideElement(role: "AXSheet", label: "Choose")]))
        await session.send(.action(click(Self.attach, at: 100)))
        let reply = await pending.value
        XCTAssertEqual(reply, .done)
        XCTAssertEqual(recorder.lines.first,
                       "Okay, one step at a time. First, click the Attach button, at the top of the window, on the right. It's glowing.")
        XCTAssertEqual(recorder.lines.last, "That's it.")
        XCTAssertTrue(recorder.effects.contains(.clear))
        let done = await session.completed
        XCTAssertEqual(done.map(\.name), ["the Attach button"])
    }

    func testASpokenControlLeftOverFromAFinishedStepDoesNotActOnTheNext() async {
        let session = GuideSession(goal: "attach a photo", clock: Self.clock, present: { _ in })
        let screen = SceneBox(scene())
        let first = Task { await session.perform(.element(Self.attach), observe: { screen.scene }) }
        await pointed(session)
        screen.set(scene([Self.attach, Self.format, Self.body, GuideElement(role: "AXSheet", label: "Choose")]))
        await session.send(.action(click(Self.attach, at: 100)))
        let firstReply = await first.value
        XCTAssertEqual(firstReply, .done)
        await session.send(.transition(.act))
        let second = Task { await session.perform(.element(Self.format), observe: { screen.scene }) }
        await pointed(session)
        screen.set(scene([Self.attach, Self.format, Self.body]))
        await session.send(.action(click(Self.format, at: 100)))
        let secondReply = await second.value
        XCTAssertEqual(secondReply, .done, "a do-this-one meant for step 1 must not do step 2")
    }

    func testJustDoItFlipsToActAndShowMeTheRestFlipsBack() async {
        let session = GuideSession(goal: "attach a photo", clock: Self.clock, present: { _ in })
        let screen = scene()
        let first = Task { await session.perform(.element(Self.attach), observe: { screen }) }
        await pointed(session)
        let ack = await session.hear(.justDoIt)
        XCTAssertEqual(ack, "Okay, I'll do the rest.")
        let reply = await first.value
        XCTAssertEqual(reply, .act)
        var mode = await session.mode
        XCTAssertEqual(mode, .act)
        let second = await session.perform(.element(Self.format), observe: { screen })
        XCTAssertEqual(second, .act, "act mode hands every later step straight back")

        _ = await session.hear(.showRest)
        mode = await session.mode
        XCTAssertEqual(mode, .show)
        let third = Task { await session.perform(.element(Self.body), observe: { screen }) }
        await pointed(session)
        let once = await session.hear(.doThisOne)
        XCTAssertEqual(once, "Okay, I'll do this one.")
        let thirdReply = await third.value
        XCTAssertEqual(thirdReply, .act)
        mode = await session.mode
        XCTAssertEqual(mode, .show, "do this one acts once and stays in show mode")
        let steps = await session.completed
        XCTAssertEqual(steps.count, 3)
    }

    func testSpokenRepeatSlowerAndGoBack() async {
        let session = GuideSession(goal: "attach a photo", clock: Self.clock, present: { _ in })
        let screen = scene()
        let first = Task { await session.perform(.element(Self.attach), observe: { screen }) }
        await pointed(session)
        _ = await session.hear(.doThisOne)
        _ = await first.value
        let second = Task { await session.perform(.element(Self.format), observe: { screen }) }
        await pointed(session)
        let repeated = await session.hear(.repeatIt)
        XCTAssertEqual(repeated, "Click the Format button, at the top of the window, on the right.")
        let slower = await session.hear(.slower)
        XCTAssertTrue(slower.hasPrefix("Take your time."))
        let back = await session.hear(.goBack)
        XCTAssertEqual(back, "The step before was: Click the Attach button, at the top of the window, on the right. Now, click the Format button, at the top of the window, on the right.")
        let stop = await session.hear(.stop)
        XCTAssertEqual(stop, "Okay, we'll stop here.")
        let reply = await second.value
        XCTAssertEqual(reply, .stop)
    }

    func testPatienceTicksThroughTheSession() async {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        let time = Clock()
        let recorder = Recorder()
        let session = GuideSession(goal: "attach a photo",
                                   clock: GuideClock(now: { time.now }, sleep: { _ in }),
                                   present: { recorder.add($0) })
        let screen = scene()
        let pending = Task { await session.perform(.element(Self.attach), observe: { screen }) }
        await pointed(session)
        for second in [105.0, 110, 125, 200] {
            time.now = second
            await session.send(.tick)
        }
        await session.send(.cancelled)
        _ = await pending.value
        XCTAssertEqual(Array(recorder.lines.dropFirst()), [step().detail, GuideMachine.offerLine])
    }

    // MARK: - DriveLoop in show mode

    final class Driver: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var didClick = false
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
        var clicked: Bool {
            get { lock.lock(); defer { lock.unlock() }; return didClick }
            set { lock.lock(); didClick = newValue; lock.unlock() }
        }
        func snapshot() -> JSONValue {
            var rows: [JSONValue] = [Self.row(3, label: "Attach", x: 800), Self.row(4, label: "Format", x: 740)]
            if clicked { rows.append(Self.row(9, role: "AXStaticText", label: "Choose a file", x: 300)) }
            return .object(["window_title": .string("New Message"), "elements": .array(rows)])
        }
        static func row(_ index: Int, role: String = "AXButton", label: String, x: Double) -> JSONValue {
            .object(["element_index": .number(Double(index)), "role": .string(role), "label": .string(label),
                     "actions": .array(role == "AXButton" ? [.string("AXPress")] : []),
                     "frame": .object(["x": .number(x), "y": .number(20), "w": .number(40), "h": .number(30)])])
        }
        func call(_ tool: String, _ args: [String: JSONValue]) -> JSONValue {
            lock.lock(); log.append(tool); lock.unlock()
            if tool == "get_window_state" { return snapshot() }
            if tool == "click" { clicked = true }
            return .object(["effect": .string("confirmed")])
        }
    }

    final class Holder: @unchecked Sendable { var session: GuideSession? }

    private func showLoop(_ driver: Driver, session: GuideSession) -> DriveLoop {
        var picks = ["e3", "done", "done"]
        return DriveLoop.inert(call: { tool, args in driver.call(tool, args) },
                         choose: { _, _ in picks.isEmpty ? nil : DriveLoop.JevChoice(id: picks.removeFirst()) },
                         ask: nil, granted: { true },
                         windowControlButtons: { _ in [] }, windowControlPress: { _, _ in false },
                         frontmostBundleID: { nil }, frontmostPID: { 42 }, frontmostWindowID: { 7 },
                         resurrector: SessionResurrector(), nativeReadOnly: { _, _ in nil },
                         guide: session)
    }

    func testShowModePointsAndWaitsInsteadOfClicking() async {
        let driver = Driver()
        let holder = Holder()
        let recorder = Recorder()
        let session = GuideSession(goal: "attach a photo", clock: Self.clock, present: { effect in
            recorder.add(effect)
            guard case .point(let step) = effect, let frame = step.target?.frame else { return }
            driver.clicked = true
            let click = UserAction(kind: .click(CGPoint(x: frame.midX, y: frame.midY)), pid: 42,
                                   element: step.target, at: 100)
            Task { await holder.session?.send(.action(click)) }
        })
        holder.session = session
        let result = await showLoop(driver, session: session)
            .run(DriveTask(goal: "attach a photo", pid: 42, windowID: 7, successContains: ["Choose a file"]),
                 session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect, "the person's verified click is the step's effect")
        XCTAssertFalse(driver.calls.contains("click"), "show mode never clicks for the person")
        XCTAssertEqual(recorder.lines.last, "That's it.")
        guard case .point(let step)? = recorder.effects.first else { return XCTFail("no point") }
        XCTAssertEqual(step.target?.label, "Attach")
        XCTAssertEqual(step.target?.frame, CGRect(x: 800, y: 20, width: 40, height: 30))
    }

    func testDoThisOneActsOnceThroughTheDispatchPath() async {
        let driver = Driver()
        let holder = Holder()
        let session = GuideSession(goal: "attach a photo", clock: Self.clock, present: { effect in
            guard case .point = effect else { return }
            Task { _ = await holder.session?.hear(.doThisOne) }
        })
        holder.session = session
        let result = await showLoop(driver, session: session)
            .run(DriveTask(goal: "attach a photo", pid: 42, windowID: 7, successContains: ["Choose a file"]),
                 session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(driver.calls.filter { $0 == "click" }.count, 1)
        let mode = await session.mode
        XCTAssertEqual(mode, .show)
    }

    // MARK: - Phrases

    func testGuideRequestPhrases() {
        XCTAssertEqual(GuideRequest.goal(in: "Show me how to attach a photo"), "attach a photo")
        XCTAssertEqual(GuideRequest.goal(in: "how do I send Linda a photo?"), "send Linda a photo")
        XCTAssertEqual(GuideRequest.goal(in: "Walk me through printing this letter"), "printing this letter")
        XCTAssertEqual(GuideRequest.goal(in: "please show me how to make the writing bigger please"),
                       "make the writing bigger")
        XCTAssertEqual(GuideRequest.goal(in: "can you walk me through joining a call"), "joining a call")
        XCTAssertNil(GuideRequest.goal(in: "open Mail"))
        XCTAssertNil(GuideRequest.goal(in: "show me how"))
        XCTAssertNil(GuideRequest.goal(in: "how do I do this"))
        XCTAssertEqual(VoiceTaskCoordinator.guideGoal(instruction: "attach a photo",
                                                      transcript: "show me how to attach a photo"),
                       "attach a photo")
        XCTAssertEqual(VoiceTaskCoordinator.guideGoal(instruction: "how do I attach a photo", transcript: nil),
                       "attach a photo")
        XCTAssertNil(VoiceTaskCoordinator.guideGoal(instruction: "attach a photo", transcript: "attach a photo"))
    }

    func testSpokenControlPhrases() {
        XCTAssertEqual(GuideControl.parse("Just do it"), .justDoIt)
        XCTAssertEqual(GuideControl.parse("just do the rest."), .justDoIt)
        XCTAssertEqual(GuideControl.parse("Show me the rest"), .showRest)
        XCTAssertEqual(GuideControl.parse("Do this one for me"), .doThisOne)
        XCTAssertEqual(GuideControl.parse("repeat that"), .repeatIt)
        XCTAssertEqual(GuideControl.parse("Where is it?"), .whereIsIt)
        XCTAssertEqual(GuideControl.parse("slower please"), .slower)
        XCTAssertEqual(GuideControl.parse("go back"), .goBack)
        XCTAssertEqual(GuideControl.parse("Stop"), .stop)
        XCTAssertEqual(GuideControl.parse("close it"), .closeIt)
        XCTAssertEqual(GuideControl.parse("undo"), .undo)
        XCTAssertNil(GuideControl.parse("yes"), "yes means nothing without an offer out")
        XCTAssertEqual(GuideControl.parse("Yes please", offerPending: true), .yes)
        XCTAssertEqual(GuideControl.parse("let me try", offerPending: true), .no)
        XCTAssertNil(GuideControl.parse("send Linda a photo"))
    }

    func testStepsBecomeANote() {
        let steps = [step(), step(Self.body, number: 2)]
        let note = GuideNote(goal: "Send a photo by email", steps: steps)
        XCTAssertEqual(note.text, """
            How to send a photo by email
            1. Click the Attach button, at the top of the window, on the right.
            2. Click in the Message box, in the middle of the window.
            """)
    }
}

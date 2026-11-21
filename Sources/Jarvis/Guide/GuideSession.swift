import CoreGraphics
import Foundation

// MARK: - Starting a guide

/// "show me how to …", "how do I …", "walk me through …" → the goal.
enum GuideRequest {
    static let openers = [
        "can you show me how to ", "could you show me how to ", "show me how to ", "show me how i ",
        "show me how do i ", "teach me how to ", "teach me to ", "can you walk me through ",
        "walk me through how to ", "walk me through ", "guide me through ", "how do i ", "how can i ",
        "how would i ", "how to ",
    ]
    private static let empty: Set<String> = ["it", "this", "that", "do it", "do this", "do that"]

    static func goal(in utterance: String) -> String? {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        for lead in ["please ", "okay ", "ok ", "jarvis ", "hey jarvis "] where text.lowercased().hasPrefix(lead) {
            text = String(text.dropFirst(lead.count))
        }
        let lower = text.lowercased()
        guard let opener = openers.first(where: { lower.hasPrefix($0) }) else { return nil }
        var goal = String(text.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
        if goal.lowercased().hasSuffix(" please") { goal = String(goal.dropLast(" please".count)) }
        guard !goal.isEmpty, !empty.contains(goal.lowercased()) else { return nil }
        return goal
    }
}

/// What the person can say during a walkthrough.
enum GuideControl: Sendable, Equatable {
    case justDoIt, showRest, doThisOne, repeatIt, whereIsIt, slower, goBack, stop
    case closeIt, undo, yes, no

    private static let phrases: [(GuideControl, Set<String>)] = [
        (.justDoIt, ["just do it", "just do it for me", "do it for me", "do the rest", "just do the rest",
                     "do the rest for me", "you do it", "do it all", "finish it", "finish it for me"]),
        (.doThisOne, ["do this one", "do this one for me", "do this step", "do this step for me",
                      "do that one", "do that one for me", "you do this one", "just this one"]),
        (.showRest, ["show me the rest", "show me the rest of it", "show me", "let me do it",
                     "ill do it", "i will do it", "back to showing me", "show me how"]),
        (.repeatIt, ["repeat", "repeat that", "say that again", "again", "what", "pardon", "sorry",
                     "come again", "one more time", "what did you say"]),
        (.whereIsIt, ["where", "where is it", "wheres that", "where is that", "i cant find it",
                      "i can not find it", "wheres it"]),
        (.slower, ["slower", "slow down", "say it slower", "more slowly", "too fast", "go slower"]),
        (.goBack, ["go back", "back", "previous step", "the step before", "go back a step",
                   "what was the last step"]),
        (.stop, ["stop", "stop it", "stop showing me", "thats enough", "cancel", "never mind"]),
        (.closeIt, ["close it", "close that", "close the menu", "close"]),
        (.undo, ["undo", "undo that", "undo it", "take it back", "bring it back"]),
    ]
    private static let yesPhrases: Set<String> = ["yes", "yes please", "yeah", "sure", "ok", "okay",
                                           "please do", "go ahead", "yes do it"]
    private static let noPhrases: Set<String> = ["no", "no thanks", "no thank you", "not yet", "let me try",
                                          "ill try", "i will try"]

    static func normalize(_ text: String) -> String {
        var words = text.lowercased()
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.first == "please" { words.removeFirst() }
        if words.last == "please", words.count > 1, words != ["yes", "please"] { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// The control these words are, or nil. "Yes" and "no" only count
    /// while Jarvis has an offer out, so a stray "okay" does nothing.
    static func parse(_ text: String, offerPending: Bool = false) -> GuideControl? {
        let phrase = normalize(text)
        if offerPending {
            if yesPhrases.contains(phrase) { return .yes }
            if noPhrases.contains(phrase) { return .no }
        }
        return phrases.first { $0.1.contains(phrase) }?.0
    }
}

// MARK: - What the session sees

/// One observation of the bound window plus which app is in front.
struct GuideScene: Sendable, Equatable {
    var pid: Int
    var windowID: Int?
    var appName: String? = nil
    var windowTitle: String? = nil
    var windowFrame: CGRect? = nil
    var elements: [GuideElement]

    var fingerprint: String {
        ([windowTitle ?? ""] + elements.map { "\($0.role)|\($0.label)|\($0.value ?? "")" })
            .joined(separator: "\n")
    }

    func contains(_ target: GuideElement) -> Bool {
        elements.contains { StepPhrasing.role($0.role) == StepPhrasing.role(target.role) && $0.label == target.label }
    }

    func shows(_ text: String) -> Bool {
        let needle = text.lowercased()
        return (windowTitle ?? "").lowercased().contains(needle)
            || elements.contains { "\($0.label) \($0.value ?? "")".lowercased().contains(needle) }
    }

    /// Menus, popovers and sheets: what a reversible detour opens.
    var transientRoles: [GuideElement] {
        elements.filter { ["menu", "menuitem", "popover", "sheet"].contains(StepPhrasing.role($0.role)) }
    }
}

struct GuideClock: Sendable {
    var now: @Sendable () -> TimeInterval
    var sleep: @Sendable (Duration) async throws -> Void
    static let live = GuideClock(now: { ProcessInfo.processInfo.systemUptime },
                                 sleep: { try await Task.sleep(for: $0) })
}

/// What the session asks the app to do: glow on a step (and show the
/// step model in the callout), a one-off pulse, a spoken line, or clear.
enum GuideEffect: Sendable, Equatable {
    case point(GuideStep)
    case pulse(CGRect)
    case say(String)
    case clear
}

enum GuideKey: Sendable, Equatable {
    case escape, undo
    var combo: String { self == .escape ? "escape" : "cmd+z" }
}

/// What the waiting step resolves to.
enum GuideTransition: Sendable, Equatable {
    /// The step is done; `rebind` when it moved the person to another
    /// window or app, which the loop must bind before the next step.
    case advance(rebind: Bool)
    case act
    case press(GuideKey)
    case replan(rebind: Bool)
    case stop
}

/// How a person's action is read, by what changed, never by blame.
enum GuideVerdict: Sendable, Equatable {
    case success(rebind: Bool)
    case nothingChanged(onTarget: Bool)
    case detour(String)
    case detourClosed
    case consequential(Consequence, label: String, undoSend: Bool)
    case changedElsewhere
    case wentElsewhere(String?, rebind: Bool)
    /// On the target of a typing step, before the text is all there.
    case typing
    case ignored
}

// MARK: - The state machine

/// Point, wait, verify, re-point, offer: one step's state as a pure
/// reducer, so the timings and wrong-click cases test on an injected clock.
struct GuideMachine: Sendable {
    static let detailAfter: TimeInterval = 10
    static let offerAfter: TimeInterval = 25
    static let missesBeforeOffer = 3
    static let praise = "That's it."
    static let offerLine = "I can do it for you if you like."
    static let missOfferLine = "Want me to do this step for you?"

    let step: GuideStep
    let pointedAt: TimeInterval
    private(set) var lastActivity: TimeInterval
    /// Lines Jarvis said without being asked: at most two per step.
    private(set) var unprompted = 0
    private(set) var misses = 0
    private(set) var offered = false
    private(set) var offerPending = false
    private(set) var detourOpen = false
    private(set) var undoOffered = false

    init(step: GuideStep, at now: TimeInterval) {
        self.step = step; pointedAt = now; lastActivity = now
    }

    private var pulse: [GuideEffect] { step.target?.frame.map { [.pulse($0)] } ?? [] }

    func opening(slow: Bool) -> [GuideEffect] {
        [.point(step), .say(StepPhrasing.opening(step, slow: slow))]
    }

    /// Patience: a fuller repeat at 10 s, the offer at 25 s, and never a
    /// third line unasked.
    mutating func tick(at now: TimeInterval) -> [GuideEffect] {
        let quiet = now - lastActivity
        if unprompted == 0, quiet >= Self.detailAfter {
            unprompted = 1
            return pulse + [.say(step.detail)]
        }
        if unprompted == 1, quiet >= Self.offerAfter {
            unprompted = 2
            guard !offered else { return [] }
            offered = true; offerPending = true
            return [.say(Self.offerLine)]
        }
        return []
    }

    /// Reads one action against the step: the clicked or focused element,
    /// the scene when the step was pointed (`baseline`), the last scene
    /// seen (`before`), and the scene now.
    static func judge(_ action: UserAction, step: GuideStep, baseline: GuideScene,
                      before: GuideScene, after: GuideScene, detourOpen: Bool) -> GuideVerdict {
        let onTarget = hits(action, step.target)
        let otherApp = after.pid != baseline.pid
        let otherWindow = after.windowID != nil && baseline.windowID != nil
            && after.windowID != baseline.windowID
        if otherApp || otherWindow {
            if onTarget { return .success(rebind: true) }
            return .wentElsewhere(otherApp ? after.appName : after.windowTitle ?? after.appName,
                                  rebind: true)
        }
        if case .appActivated = action.kind { return .ignored }
        let changed = before.fingerprint != after.fingerprint
        let met: Bool
        let named: Bool
        switch step.expect {
        case .anyChange:
            met = changed || action.kind == .menuOpened || action.kind == .windowCreated
            named = false
        case .appears(let text):
            met = after.shows(text) && !baseline.shows(text)
            named = true
        }
        if met, onTarget || step.target == nil || named { return .success(rebind: false) }
        if onTarget, step.target.map(StepPhrasing.isTextEntry) == true {
            if named, action.kind == .focusChanged || action.kind == .valueChanged || isClick(action) {
                return .typing
            }
            if !named, action.kind == .focusChanged || isClick(action) { return .success(rebind: false) }
        }
        let opened = after.transientRoles.filter { !baseline.transientRoles.contains($0) }
        if detourOpen, opened.isEmpty { return .detourClosed }
        if action.kind == .menuOpened || !opened.isEmpty {
            return .detour(detourName(action.element, opened: opened))
        }
        if changed, let label = action.element?.label,
           let consequence = Consequence.of(control: label), consequence != .unnamed {
            return .consequential(consequence, label: label,
                                  undoSend: after.shows("undo send"))
        }
        guard changed else { return .nothingChanged(onTarget: onTarget) }
        if action.kind == .windowCreated { return .detour("a new window") }
        if let target = step.target, !after.contains(target) {
            return .wentElsewhere(nil, rebind: false)
        }
        return .changedElsewhere
    }

    private static func isClick(_ action: UserAction) -> Bool {
        if case .click = action.kind { return true }
        return false
    }

    static func hits(_ action: UserAction, _ target: GuideElement?) -> Bool {
        guard let target else { return false }
        if case .click(let point) = action.kind, let frame = target.frame,
           frame.insetBy(dx: -4, dy: -4).contains(point) {
            return true
        }
        guard let element = action.element else { return false }
        let sameRole = StepPhrasing.role(element.role) == StepPhrasing.role(target.role)
        if sameRole, !target.label.isEmpty, element.label == target.label {
            if let a = element.frame, let b = target.frame { return a.intersects(b.insetBy(dx: -4, dy: -4)) }
            return true
        }
        return false
    }

    private static func detourName(_ element: GuideElement?, opened: [GuideElement]) -> String {
        if let element, !element.label.isEmpty,
           ["menubaritem", "popupbutton", "menubutton", "button"].contains(StepPhrasing.role(element.role)) {
            return "the \(element.label) menu"
        }
        let roles = Set(opened.map { StepPhrasing.role($0.role) })
        if roles.contains("sheet") { return "a new panel" }
        if roles.contains("popover") { return "a small popup" }
        return "a menu"
    }

    private mutating func missed(_ effects: [GuideEffect]) -> [GuideEffect] {
        misses += 1
        guard misses >= Self.missesBeforeOffer, !offered else { return effects }
        offered = true; offerPending = true
        return effects + [.say(Self.missOfferLine)]
    }

    mutating func judged(_ verdict: GuideVerdict, at now: TimeInterval)
        -> (effects: [GuideEffect], transition: GuideTransition?) {
        if verdict != .ignored { lastActivity = now }
        switch verdict {
        case .ignored, .typing:
            return ([], nil)
        case .success(let rebind):
            return ([.clear, .say(Self.praise)], .advance(rebind: rebind))
        case .nothingChanged(let onTarget):
            let line = onTarget ? "That's the right one. Try it once more."
                : "That's okay. It's this one, \(step.name)."
            return (missed(pulse + [.say(line)]), nil)
        case .detour(let what):
            detourOpen = true
            return (missed([.say("That opened \(what). Let's close it: press Escape, or say \u{201C}close it\u{201D}.")]), nil)
        case .detourClosed:
            detourOpen = false
            return (pulse + [.say("That's it. Now \(step.name).")], nil)
        case .consequential(let consequence, let label, let undoSend):
            undoOffered = true
            let line: String
            switch consequence {
            case .send where undoSend:
                line = "That sent it. It can still be taken back: say \u{201C}undo\u{201D} and I'll press Undo Send."
            case .send:
                line = "That pressed \(label), so it may have gone. Say \u{201C}undo\u{201D} and I'll try to take it back."
            case .delete:
                line = "That pressed \(label), which deletes. Say \u{201C}undo\u{201D} and I'll bring it back."
            default:
                line = "That pressed \(label). Say \u{201C}undo\u{201D} and I'll try to take it back."
            }
            return (missed([.say(line)]), nil)
        case .changedElsewhere:
            return (missed(pulse + [.say("That's okay. It's still this one, \(step.name).")]), nil)
        case .wentElsewhere(let place, let rebind):
            let line = place.map { "We're in \($0) now. That's fine, let's carry on from here." }
                ?? "That's fine, let's carry on from here."
            return ([.clear, .say(line)], .replan(rebind: rebind))
        }
    }

    /// A spoken control while this step waits. These are prompted lines,
    /// so they never count toward patience.
    mutating func heard(_ control: GuideControl, previous: GuideStep?, slow: Bool,
                        at now: TimeInterval) -> (effects: [GuideEffect], transition: GuideTransition?) {
        lastActivity = now
        switch control {
        case .repeatIt:
            return (pulse + [.say(slow ? step.slow : step.instruction)], nil)
        case .whereIsIt:
            return (pulse + [.say(step.detail)], nil)
        case .slower:
            return (pulse + [.say(step.slow)], nil)
        case .goBack:
            guard let previous else {
                return ([.say("This is the first step. \(step.instruction)")], nil)
            }
            return ([.say("The step before was: \(previous.instruction) Now, \(StepPhrasing.lowercasedFirst(step.instruction))")], nil)
        case .justDoIt:
            return ([.clear, .say("Okay, I'll do the rest.")], .act)
        case .doThisOne:
            offerPending = false
            return ([.clear, .say("Okay, I'll do this one.")], .act)
        case .yes:
            guard offerPending else { return ([], nil) }
            offerPending = false
            return ([.clear, .say("Okay, I'll do this one.")], .act)
        case .no:
            offerPending = false
            return ([.say("Okay. Take your time.")], nil)
        case .showRest:
            return (pulse + [.say("Okay, you do it. \(step.instruction)")], nil)
        case .closeIt:
            guard detourOpen else { return ([.say("There's nothing open to close. \(step.instruction)")], nil) }
            return ([.say("Closing it.")], .press(.escape))
        case .undo:
            guard undoOffered else { return ([.say("There's nothing to undo yet.")], nil) }
            undoOffered = false
            return ([.say("Undoing that.")], .press(.undo))
        case .stop:
            return ([.clear, .say("Okay, we'll stop here.")], .stop)
        }
    }

    /// After Jarvis pressed Escape or Undo for the person: read the scene
    /// again and say what happened, honestly.
    mutating func pressed(_ key: GuideKey, before: GuideScene?, after: GuideScene?,
                          baseline: GuideScene, at now: TimeInterval) -> [GuideEffect] {
        lastActivity = now
        let changed = before?.fingerprint != after?.fingerprint
        switch key {
        case .escape:
            let stillOpen = after.map { scene in
                scene.transientRoles.contains { !baseline.transientRoles.contains($0) }
            } ?? true
            guard !stillOpen else { return [.say("It's still open. Try pressing Escape.")] }
            detourOpen = false
            return pulse + [.say("That's it. Now \(step.name).")]
        case .undo:
            guard changed, before != nil, after != nil else {
                return [.say("I pressed Undo, but I couldn't see anything change.")]
            }
            return pulse + [.say("I undid it. Now, \(StepPhrasing.lowercasedFirst(step.instruction))")]
        }
    }
}

// MARK: - The session

/// One walkthrough. DriveLoop hands it each step Jev chose; it points,
/// waits for the person and verifies, then says how the step resolved.
/// The mode is the walkthrough's: "just do it" flips it to `.act` from
/// the current step and "show me the rest" flips it back.
actor GuideSession {
    enum Reply: Sendable, Equatable {
        /// The person did it and the effect was seen.
        case done
        /// Jarvis should do this step, through the consented action path.
        case act
        /// Jarvis should press this key for the person, then `resume`.
        case press(GuideKey)
        case replan(rebind: Bool)
        case stop
    }

    /// Thrown out of a round when the person moved to another app: the
    /// coordinator binds the new front app and carries on.
    struct Rebind: Error {}
    static let rebindReason = "guide moved to another app"
    static let settleDelay: Duration = .milliseconds(400)

    enum Event: Sendable {
        case action(UserAction)
        case tick
        case transition(GuideTransition)
        case cancelled
    }

    nonisolated let goal: String
    let hints: [GuideHint]
    private(set) var mode: DriveLoop.ExecutionMode = .show
    private(set) var completed: [GuideStep] = []
    private(set) var slow = false
    private(set) var machine: GuideMachine?
    private var baseline: GuideScene?
    private var latest: GuideScene?
    private var observe: (@Sendable () async -> GuideScene?)?
    private var mailbox: [Event] = []
    private var waiter: CheckedContinuation<Event, Never>?
    private var ticker: Task<Void, Never>?
    private let clock: GuideClock
    private let present: @Sendable (GuideEffect) async -> Void

    init(goal: String, hints: [GuideHint] = [], clock: GuideClock = .live,
         present: @escaping @Sendable (GuideEffect) async -> Void) {
        self.goal = goal; self.hints = hints
        self.clock = clock; self.present = present
    }

    var offerPending: Bool { machine?.offerPending ?? false }
    var currentStep: GuideStep? { machine?.step }
    var stepNumber: Int { completed.count + 1 }

    func hint(for number: Int) -> GuideHint? {
        hints.indices.contains(number - 1) ? hints[number - 1] : nil
    }

    /// The recipe's step hints as Jev context, beside the spoken goal.
    nonisolated var hintContext: String? {
        let lines = hints.enumerated().compactMap { index, hint -> String? in
            hint.control.map { "\(index + 1). \($0)" }
        }
        return lines.isEmpty ? nil : "Guide steps: " + lines.joined(separator: "; ")
    }

    /// One patience tick a second, on the session's clock. Tests leave it
    /// off and send `.tick` themselves.
    func startTicking(every interval: Duration = .seconds(1)) {
        guard ticker == nil else { return }
        let clock = self.clock
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(interval)
                guard !Task.isCancelled else { return }
                await self?.send(.tick)
            }
        }
    }

    func end() {
        ticker?.cancel(); ticker = nil
        send(.cancelled)
    }

    func send(_ event: Event) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            mailbox.append(event)
        }
    }

    private func nextEvent() async -> Event {
        if !mailbox.isEmpty { return mailbox.removeFirst() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.send(.cancelled) }
        }
    }

    private func apply(_ effects: [GuideEffect]) async {
        for effect in effects { await present(effect) }
    }

    /// Show one step: point at it, wait for the person, verify the effect.
    /// In act mode the step is recorded and handed straight back.
    func perform(_ action: GuideAction, observe: @escaping @Sendable () async -> GuideScene?) async -> Reply {
        self.observe = observe
        let scene = await observe()
        let step = StepPhrasing.step(number: stepNumber, action: action, window: scene?.windowFrame,
                                     scene: scene?.elements ?? [], hint: hint(for: stepNumber))
        guard mode == .show else {
            completed.append(step)
            return .act
        }
        mailbox.removeAll {
            switch $0 {
            case .tick, .transition: return true
            case .action, .cancelled: return false
            }
        }
        let fresh = GuideMachine(step: step, at: clock.now())
        machine = fresh
        baseline = scene; latest = scene
        await apply(fresh.opening(slow: slow))
        return await waitLoop()
    }

    /// Carry on waiting after Jarvis pressed a key for the person.
    func resume(after key: GuideKey) async -> Reply {
        guard var current = machine, let baseline else { return .stop }
        let after = await observe?()
        let effects = current.pressed(key, before: latest, after: after, baseline: baseline, at: clock.now())
        machine = current
        if let after { latest = after }
        await apply(effects)
        return await waitLoop()
    }

    private func waitLoop() async -> Reply {
        while let current = machine {
            switch await nextEvent() {
            case .cancelled:
                machine = nil
                return .stop
            case .transition(let transition):
                return finish(transition)
            case .tick:
                if current.step.target == nil || current.step.expect != .anyChange,
                   let transition = await verifyQuietly() {
                    return finish(transition)
                }
                guard var updated = machine else { continue }
                let effects = updated.tick(at: clock.now())
                machine = updated
                await apply(effects)
            case .action(let action):
                guard action.at >= current.pointedAt, let baseline else { continue }
                try? await clock.sleep(Self.settleDelay)
                mailbox.removeAll {
                    if case .action(let later) = $0 { return later.at <= clock.now() }
                    return false
                }
                guard let after = await observe?(), let before = latest,
                      var updated = machine else { continue }
                let verdict = GuideMachine.judge(action, step: updated.step, baseline: baseline,
                                                 before: before, after: after,
                                                 detourOpen: updated.detourOpen)
                let outcome = updated.judged(verdict, at: clock.now())
                machine = updated
                latest = after
                await apply(outcome.effects)
                if let transition = outcome.transition { return finish(transition) }
            }
        }
        return .stop
    }

    /// Keyboard steps and steps with a named effect check the screen each
    /// tick, so progress made without a click still counts.
    private func verifyQuietly() async -> GuideTransition? {
        guard var current = machine, let baseline, let before = latest,
              let after = await observe?() else { return nil }
        let action = UserAction(kind: .valueChanged, pid: after.pid, element: nil, at: clock.now())
        let verdict = GuideMachine.judge(action, step: current.step, baseline: baseline,
                                         before: before, after: after, detourOpen: current.detourOpen)
        switch verdict {
        case .success, .wentElsewhere: break
        default: return nil
        }
        let outcome = current.judged(verdict, at: clock.now())
        machine = current
        latest = after
        await apply(outcome.effects)
        return outcome.transition
    }

    private func finish(_ transition: GuideTransition) -> Reply {
        let step = machine?.step
        switch transition {
        case .advance(let rebind):
            if let step { completed.append(step) }
            machine = nil
            return rebind ? .replan(rebind: true) : .done
        case .act:
            if let step { completed.append(step) }
            machine = nil
            return .act
        case .press(let key):
            return .press(key)
        case .replan(let rebind):
            machine = nil
            return .replan(rebind: rebind)
        case .stop:
            machine = nil
            return .stop
        }
    }

    /// A spoken control. Returns the line to speak; a control that ends
    /// the wait (act, press, stop) wakes the waiting step.
    func hear(_ control: GuideControl) async -> String {
        switch control {
        case .justDoIt:
            mode = .act
        case .showRest:
            mode = .show
            guard machine != nil else { return "Okay, I'll show you the next step." }
        case .slower:
            slow = true
        default:
            break
        }
        guard var current = machine else {
            return control == .justDoIt ? "Okay, I'll do the rest." : "Hold on, I'm still looking."
        }
        let outcome = current.heard(control, previous: completed.last, slow: slow, at: clock.now())
        machine = current
        var says: [String] = []
        for effect in outcome.effects {
            if case .say(let line) = effect { says.append(line) } else { await present(effect) }
        }
        if let transition = outcome.transition { send(.transition(transition)) }
        return says.joined(separator: " ")
    }
}

// MARK: - Writing the steps down

/// "Want me to write these steps in a note?" The note is created by an
/// ordinary consented task, never a new write path.
struct GuideNote: Sendable, Equatable {
    static let offer = "Want me to write these steps in a note, so you have them for next time?"
    static let instruction = "make a new note in Notes and type the steps into it"
    var title: String
    var steps: [String]

    init(goal: String, steps: [GuideStep]) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        title = "How to " + StepPhrasing.lowercasedFirst(trimmed)
        self.steps = steps.map(\.instruction)
    }

    /// Notes takes its first line as the title.
    var text: String {
        ([title] + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
    }
}

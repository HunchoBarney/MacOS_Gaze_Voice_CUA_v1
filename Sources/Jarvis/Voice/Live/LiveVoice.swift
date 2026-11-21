import AVFoundation
import Foundation
import os

/// The microphone side of `LiveVoice`: LiveKit's engine in the app, a fake
/// in tests.
protocol LiveMicrophoneDriving: AnyObject {
    var relay: LiveInputRelay { get }
    /// Every input buffer, on the audio thread.
    var onInput: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }
    func start() throws
    func stop()
    /// The chosen microphone's Core Audio UID; empty for the system default.
    func useInput(uid: String)
}

#if canImport(LiveKitWebRTC)
extension LiveMicrophone: LiveMicrophoneDriving {}
#endif

/// KAR-75 L3: hands-free listening on GPT-Live, behind `voice.live`.
///
/// One engine owns the microphone from the moment listening is armed. The
/// wake word listens to it on the Mac; "Hey Jarvis" opens a Live session and
/// the words said with it are replayed into the session (`LiveInputRelay`).
/// `LiveListening` decides when the session closes. The glow shows when
/// Jarvis is hearing or thinking, without a sound.
///
/// KAR-75 L10: once this month's Live voice is used up (`allowance` is in
/// basic voice, or the broker refuses with `live_limit`), a wake opens no
/// session. The request is recorded on the Mac until the user pauses and
/// handed to `onBasicRequest`. After each wake, Live or basic, the allowance
/// is read again, so basic voice ends once the Worker says the month
/// renewed; crossing the warning share shows one line on the glow and, when
/// replies are spoken, Live says it once the next time the user talks.
@MainActor
final class LiveVoice {
    enum Glow: Equatable { case hidden, hearing, thinking }

    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "live")

    private(set) var listening: LiveListening
    private(set) var armed = false
    private(set) var glow: Glow = .hidden { didSet { if glow != oldValue { onGlow?(glow) } } }
    var onGlow: ((Glow) -> Void)?
    /// "Stop", "cancel" and "undo", for whatever is running the work.
    var onControl: ((LiveControlWord) -> Void)?
    /// This month's Live voice. Nil leaves every wake on Live.
    var allowance: LiveAllowance?
    /// A request heard in basic voice: mono samples at the relay's rate,
    /// and the day Live voice is back.
    var onBasicRequest: (@MainActor (_ samples: [Float], _ until: Date) async -> Void)?
    /// A quiet line for the glow, such as the warning share.
    var onNotice: ((String) -> Void)?
    /// Whether Live may say the warning too ("Say replies out loud").
    var speaksWarnings: () -> Bool = { false }

    /// How a wake went, in seconds from the end of the wake phrase.
    struct OneBreath: Equatable {
        /// Until session.started.
        var started: Double
        /// Speech still waiting to be played in at session.started.
        var behind: Double
        /// Until Live's first reply or delegation.
        var first: Double?
        var firstWasDelegation = false
        /// Quiet audio skipped to catch up, by the first reply.
        var skipped: Double = 0
    }
    /// Called once per wake, at Live's first reply or delegation.
    var onOneBreath: ((OneBreath) -> Void)?
    /// Live's reply so far in this turn, for showing it when it isn't spoken.
    var onReply: ((String) -> Void)?
    /// Every event of the open session, and the close of one Jarvis ended,
    /// for the delegation bridge.
    var onSessionEvent: ((LiveSessionEvent) -> Void)?
    /// The open session, for answering its delegations.
    var openSession: LiveSessionSending? { session }

    private let microphone: LiveMicrophoneDriving
    private let wakeWord: WakeWordDetecting
    private let makeSession: @MainActor (_ name: String) -> LiveSession
    private let now: () -> TimeInterval
    private var session: LiveSession?
    private var wokeAt: TimeInterval?
    private var oneBreath: OneBreath?
    private var reply = ""
    private var userTalking = false
    private var wakeTestHeard: Bool?
    private var wakeTestFrom = TimeInterval.infinity
    private var timer: Task<Void, Never>?
    private var basicTurn: Task<Void, Never>?
    /// Set while basic voice records the request, then works on it.
    private var basicGlow: Glow?
    private var warning: String?

    init(microphone: LiveMicrophoneDriving, wakeWord: WakeWordDetecting,
         timings: LiveListening.Timings = .init(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeSession: @escaping @MainActor (_ name: String) -> LiveSession) {
        self.microphone = microphone
        self.wakeWord = wakeWord
        self.now = now
        self.makeSession = makeSession
        listening = LiveListening(name: "", timings: timings)
    }

    /// Starts the microphone and the wake word for `name`.
    func arm(name: String) throws {
        guard !armed else { return }
        listening = LiveListening(name: name, timings: listening.timings)
        let detector = wakeWord
        microphone.onInput = { buffer, time in detector.hear(buffer, at: time) }
        try microphone.start()
        do {
            try listenForWake()
        } catch {
            microphone.stop()
            throw error
        }
        armed = true
        readAllowance()
    }

    /// Records from this microphone from now on.
    func useInput(uid: String) {
        microphone.useInput(uid: uid)
    }

    /// Closes any session and releases the microphone.
    func disarm() {
        guard armed else { return }
        armed = false
        apply(listening.handle(.pause, at: now()))
        wakeWord.stop()
        microphone.stop()
        microphone.onInput = nil
        _ = listening.handle(.resume, at: now())
    }

    /// Settings' Test: after `prelude` (Jarvis saying the phrase, which
    /// doesn't count), whether the person's wake phrase is heard within
    /// `seconds`. A phrase that ended before the listening window, such as
    /// a late confirmation of Jarvis's own, doesn't count. No wake during the
    /// test opens a session.
    func testWake(for seconds: Double, after prelude: @MainActor () async -> Void) async -> Bool {
        guard armed, listening.state == .asleep else { return false }
        wakeTestHeard = false
        wakeTestFrom = .infinity
        defer { wakeTestHeard = nil }
        await prelude()
        wakeTestFrom = now()
        let deadline = wakeTestFrom + seconds
        while wakeTestHeard == false, now() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return wakeTestHeard == true
    }

    /// The wake phrase ended at `moment` (systemUptime).
    func wake(at moment: TimeInterval) {
        guard armed else { return }
        if wakeTestHeard != nil {
            if moment >= wakeTestFrom { wakeTestHeard = true }
            return
        }
        guard listening.handle(.wake, at: now()).contains(.openSession) else { return }
        wakeWord.stop()
        microphone.relay.capture(since: moment)
        wokeAt = moment
        oneBreath = nil
        reply = ""
        userTalking = false
        if case .basic(let until) = allowance?.mode { return listenOnDevice(until: until) }
        let warning = warning
        self.warning = nil
        let session = makeSession(listening.name)
        self.session = session
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.session === session else { return }
            self.receive(event)
        }
        Task { [weak self] in
            do {
                try await session.start()
            } catch {
                Self.log.error("live_start_failed \(error.localizedDescription, privacy: .public)")
                guard let self, self.session === session else { return }
                if let allowance = self.allowance, allowance.refused(error), case .basic(let until) = allowance.mode {
                    self.session = nil
                    self.restartMicrophone()
                    self.listenOnDevice(until: until)
                    return
                }
                self.ended()
                return
            }
            guard let self, self.session === session else { return }
            self.microphone.relay.startSending()
            let stats = self.microphone.relay.stats
            self.oneBreath = OneBreath(started: self.since(moment), behind: stats.behind)
            Self.log.notice("live_one_breath started=\(self.since(moment), privacy: .public)s behind=\(stats.behind, privacy: .public)s")
            if stats.overflowed {
                session.send(LiveAppend(kind: .instructions, content: Self.sayAgain, delegationID: nil))
            }
            if let warning, self.speaksWarnings() {
                session.send(LiveAppend(kind: .instructions, content: Self.mention(warning), delegationID: nil))
            }
            self.apply(self.listening.handle(.started, at: self.now()))
        }
        refresh()
    }

    static let sayAgain = "The user's first words were lost while connecting. Ask them, in a few words, to say that again."

    static func mention(_ warning: String) -> String {
        "After you answer the user's request, tell them this in one sentence: \(warning)"
    }

    static func instructions(name: String) -> String {
        """
        You are \(name), a calm, friendly voice assistant on a Mac. Be clear and brief: one short sentence.
        The user wakes you by saying "Hey \(name)", often with the request in the same breath; answer the request.

        Backchannel policy: Use few backchannels.

        Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

        Delegation policy:
        Backend tools:
        - Mac: open apps, create notes, change settings such as volume, show the calendar, search the web.

        Delegate to the backend when:
        - The user asks the Mac to do something.

        Do not delegate when:
        - You can answer from your own knowledge, such as facts, spelling or arithmetic.

        Delegate to the backend before saying an action is done.
        Do not guess the result while waiting.
        """
    }

    private func receive(_ event: LiveSessionEvent) {
        onSessionEvent?(event)
        let at = now()
        switch event {
        case .inputTranscript(let delta):
            if !userTalking { reply = "" }
            userTalking = true
            apply(listening.handle(.heard(delta.text), at: at))
        case .outputTranscript(let delta):
            userTalking = false
            reply += delta.text
            onReply?(reply)
            noteReply(delegation: false)
            apply(listening.handle(.answered, at: at))
        case .delegation:
            userTalking = false
            noteReply(delegation: true)
            apply(listening.handle(.delegated, at: at))
        case .paused:
            userTalking = false
            apply(listening.handle(.paused, at: at))
        case .resumed:
            apply(listening.handle(.resumed, at: at))
        case .closed:
            ended()
        case .started, .usage, .error:
            break
        }
    }

    private func noteReply(delegation: Bool) {
        guard var breath = oneBreath, breath.first == nil, let wokeAt else { return }
        breath.first = since(wokeAt)
        breath.firstWasDelegation = delegation
        breath.skipped = microphone.relay.stats.skipped
        oneBreath = breath
        Self.log.notice("live_one_breath first=\(breath.first ?? 0, privacy: .public)s delegation=\(delegation, privacy: .public) skipped=\(breath.skipped, privacy: .public)s")
        onOneBreath?(breath)
    }

    private func since(_ moment: TimeInterval) -> Double { ((now() - moment) * 1000).rounded() / 1000 }

    private func apply(_ effects: [LiveListening.Effect]) {
        for effect in effects {
            switch effect {
            case .openSession: break
            case .closeSession:
                ended(closing: session)
            case .control(let word):
                onControl?(word)
            }
        }
        refresh()
    }

    /// Basic voice: records the request on the Mac until the user has
    /// spoken and then paused, or the capture nears the relay's limit, and
    /// hands it over. Nothing heard by the false-wake limit is a false wake.
    private func listenOnDevice(until: Date) {
        basicGlow = .hearing
        refresh()
        let relay = microphone.relay
        let settle = listening.timings.settle
        let falseWake = listening.timings.falseWake
        let full = relay.maxBehind - 0.25
        let began = now()
        basicTurn = Task { [weak self] in
            var spoken = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let stats = relay.stats
                spoken = stats.spoken
                if spoken > 0, stats.quiet >= settle { break }
                if stats.overflowed || stats.behind >= full || self.now() - began >= falseWake { break }
            }
            guard let self, !Task.isCancelled else { return }
            let samples = relay.take()
            let heard = spoken
            Self.log.notice("live_basic_request spoken=\(heard, privacy: .public)s")
            if heard > 0, let handle = self.onBasicRequest {
                self.basicGlow = .thinking
                self.refresh()
                await handle(samples, until)
            }
            guard !Task.isCancelled else { return }
            self.ended(restart: false)
        }
    }

    /// The session is gone: back to the wake word. Closing a call stops
    /// LiveKit's engine (ThirdParty/WebRTC/README.md), so once `closing` has
    /// closed, recording starts again for the wake word. Basic voice never
    /// opened a call, so its recording carries on (`restart` false).
    private func ended(closing: LiveSession? = nil, restart: Bool = true) {
        if closing != nil { onSessionEvent?(.closed(reason: .closeRequested, usage: nil)) }
        session = nil
        wokeAt = nil
        basicTurn?.cancel()
        basicTurn = nil
        basicGlow = nil
        microphone.relay.stop()
        _ = listening.handle(.ended, at: now())
        if armed, listening.state == .asleep { try? listenForWake() }
        refresh()
        readAllowance()
        guard restart else { return }
        Task { [weak self] in
            _ = await closing?.close()
            guard let self, self.armed else { return }
            self.restartMicrophone()
        }
    }

    private func restartMicrophone() {
        do { try microphone.start() } catch {
            Self.log.error("live_microphone_restart_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads this month's Live voice. Crossing the warning share shows its
    /// line now and keeps it for Live to say at the next wake.
    private func readAllowance() {
        guard let allowance else { return }
        Task { [weak self] in
            await allowance.refresh()
            guard let self, let line = allowance.takeWarning() else { return }
            self.warning = line
            self.onNotice?(line)
        }
    }

    private func listenForWake() throws {
        try wakeWord.start(name: listening.name) { [weak self] moment in self?.wake(at: moment) }
    }

    private func refresh() {
        let at = now()
        if let basicGlow {
            glow = basicGlow
            timer?.cancel()
            return
        }
        switch listening.state {
        case .connecting, .talking: glow = listening.thinking(at: at) ? .thinking : .hearing
        case .standby: glow = listening.thinking(at: at) ? .thinking : .hidden
        case .asleep, .off: glow = .hidden
        }
        timer?.cancel()
        guard let deadline = listening.deadline(after: at) else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - at)))
            guard let self, !Task.isCancelled else { return }
            self.apply(self.listening.handle(.tick, at: self.now()))
        }
    }
}

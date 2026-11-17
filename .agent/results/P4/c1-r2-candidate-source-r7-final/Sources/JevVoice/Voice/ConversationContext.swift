import AVFoundation
import Foundation
import JevVoiceCore

enum ConversationScope: Sendable, Equatable {
    case window(app: String, id: Int)
    case application(VoiceAdmissionContext.Entity)

    static func window(_ context: VoiceAdmissionContext) -> Self? {
        guard let app = context.targetAppID, !app.isEmpty,
              let id = context.windowID, id > 0 else { return nil }
        return .window(app: app, id: id)
    }

    func matches(_ context: VoiceAdmissionContext) -> Bool {
        switch self {
        case .window(let app, let id): return context.targetAppID == app && context.windowID == id
        case .application(let entity): return VoiceSemanticRouter.targetIsCurrent(entity, context: context)
        }
    }

    var appID: String {
        switch self {
        case .window(let app, _): app
        case .application(let entity): entity.id
        }
    }

    var windowID: Int? {
        if case .window(_, let id) = self { return id }
        return nil
    }

    var state: JSONValue {
        .object(["app": .string(appID), "window": windowID.map { .number(Double($0)) } ?? .null])
    }
}

struct ConversationDecision: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case task, scroll, continueScroll = "continue_scroll", answer
        case stop, pause, incomplete, ignore, clarify
    }
    let kind: Kind
    var scope: ConversationScope?
    var direction: String?
    var small = false
    var windowScroll: WindowScrollRequest?

    var scrollGoal: String? {
        guard let direction, ["up", "down", "left", "right"].contains(direction) else { return nil }
        return "scroll \(direction)" + (small ? " a little" : "")
    }
}

struct ConversationContext: Sendable {
    struct Scroll: Sendable {
        let scope: ConversationScope
        let direction: String
        let small: Bool
        let viewport: NativeWindowObservation.ScrollViewport
    }

    private(set) var fragment: String?
    private var fragmentScope: ConversationScope?
    private(set) var lastGoal: String?
    private(set) var lastScope: ConversationScope?
    private(set) var lastVerified = false
    var scroll: Scroll?

    static func localControl(_ text: String) -> ConversationDecision.Kind? {
        let text = VoiceAdmissionPolicy.normalized(
            VoiceAdmissionPolicy.commandText(text, context: VoiceAdmissionContext()))
        if ["stop", "stop scrolling", "stop please", "stop now", "no stop", "ok stop", "okay stop",
            "cancel", "cancel that", "never mind", "nevermind", "that s enough"]
            .contains(text) { return .stop }
        if ["pause listening", "stop listening", "pause jev", "pause jarvis"].contains(text) { return .pause }
        return nil
    }

    static func isNegativeFragment(_ text: String) -> Bool {
        let normalized = VoiceAdmissionPolicy.normalized(
            VoiceAdmissionPolicy.commandText(text, context: VoiceAdmissionContext()))
        return ["don t", "dont", "do not", "not", "never", "without", "unless"].contains(normalized)
    }

    static func localControl(_ text: String, after previous: String?) -> ConversationDecision.Kind? {
        if let previous, isNegativeFragment(previous) { return nil }
        return localControl(text)
    }

    func combined(_ text: String, context: VoiceAdmissionContext) throws -> String {
        guard let fragment else { return text }
        guard let fragmentScope, fragmentScope.matches(context) else {
            throw VoiceError("The target changed while that request was unfinished. Please restate it.")
        }
        let combined = fragment + "\n" + text
        guard combined.utf8.count <= 4000 else {
            throw VoiceError("That unfinished request is too long to interpret safely. Please restate it.")
        }
        return combined
    }

    mutating func hold(_ text: String, scope: ConversationScope?) {
        fragment = text
        fragmentScope = scope
    }

    mutating func remember(_ goal: String, scope: ConversationScope) {
        fragment = nil; fragmentScope = nil
        lastGoal = goal; lastScope = scope
        lastVerified = false
    }

    mutating func recordVerification(_ verified: Bool) { lastVerified = verified }
    mutating func discardFragment() { fragment = nil; fragmentScope = nil }

    var state: JSONValue {
        .object([
            "last_request": lastGoal.map(JSONValue.string) ?? .null,
            "last_request_verified": .bool(lastVerified),
            "last_scope": lastScope?.state ?? .null,
            "verified_scroll": scroll.map { .object([
                "scope": $0.scope.state, "direction": .string($0.direction), "small": .bool($0.small)
            ]) } ?? .null,
        ])
    }
}

enum ConversationListeningState: Equatable {
    case off, preparing, listening, paused, unavailable(String)
}

enum ConversationPresentation {
    case began(UUID, TimeInterval)
    case sealed(UUID, TimeInterval)
    case final(UUID, String)
    case feedback(UUID, String)
    case ignored(UUID)
    case waiting(UUID)
    case scrolling(UUID, Bool)
}

struct ConversationCommand: Sendable {
    let session: UUID
    let epoch: UUID
    let admission: VoiceAdmission
    let text: String
    let decision: ConversationDecision
    let context: VoiceAdmissionContext
    let continuation: NativeWindowObservation.ScrollViewport?
}

struct ConversationEffect: Sendable {
    let verified: Bool
    let waitingForAnswer: Bool
    let message: String
    var scroll: NativeWindowObservation.VerifiedScroll?
}

@MainActor
final class ConversationSession {
    private struct Pending: Sendable {
        let utterance: ConversationCapture.Utterance
        let context: VoiceAdmissionContext
    }
    private struct Final: Sendable {
        let pending: Pending
        let owner: LocalSpeechSession
        let admission: VoiceAdmission
        let epoch: UUID
    }

    let capture: ConversationCapture
    var makeSpeechSession: ((VoiceAdmissionContext) throws -> LocalSpeechSession)?
    var readContext: (() -> VoiceAdmissionContext)?
    var interpret: (@MainActor @Sendable (String, VoiceAdmissionContext, ConversationContext) async throws -> ConversationDecision)?
    var execute: ((ConversationCommand) async throws -> ConversationEffect)?
    var beforeAction: (() async -> Void)?
    var onControl: ((ConversationDecision.Kind) -> Void)?
    var onBargeIn: (() -> Void)?
    var onCancelRepetition: (() -> Void)?
    var onEvent: ((ConversationPresentation) -> Void)?
    var onEnded: ((UUID, String) -> Void)?
    var onDiagnostic: (@Sendable (VoiceSpeechDiagnostic) -> Void)?
    private(set) var id: UUID?
    private var epoch = UUID()
    private var contexts: [UUID: VoiceAdmissionContext] = [:]
    private var pending: [Pending] = []
    private var finals: [Final] = []
    private var owners: [UUID: LocalSpeechSession] = [:]
    private var memory = ConversationContext()
    private var feedTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var repetitionTask: Task<Void, Never>?
    private var repetitionID: UUID?
    private var previousFinal: String?

    init(capture: ConversationCapture = ConversationCapture()) { self.capture = capture }

    func prepare() async throws { try await capture.prepare() }

    func start(feed: ConvertedAudioFeed, session: UUID) async throws {
        guard id == nil, makeSpeechSession != nil, readContext != nil,
              interpret != nil, execute != nil, onControl != nil else {
            throw VoiceError("Hands-free voice is not ready.")
        }
        let stream = try await capture.begin(session: session)
        try Task.checkCancellation()
        id = session
        epoch = UUID()
        memory = ConversationContext()
        previousFinal = nil
        eventTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, self.id == session, !Task.isCancelled else { return }
                    switch event {
                    case .began(let owner, let turn, _, let detectedAt):
                        guard owner == session,
                              ProcessInfo.processInfo.systemUptime - detectedAt <= 0.5 else {
                            throw VoiceError("I couldn't capture the speaking target in time. Please try again.")
                        }
                        guard let context = self.readContext?() else { throw LocalSpeechError.unavailable }
                        self.contexts[turn] = context
                        self.onBargeIn?()
                        self.onEvent?(.began(turn, detectedAt))
                    case .utterance(let utterance):
                        guard utterance.session == session,
                              let context = self.contexts.removeValue(forKey: utterance.id) else {
                            throw LocalSpeechError.captureLoss
                        }
                        self.onEvent?(.sealed(utterance.id, utterance.sealedAt))
                        self.pending.append(.init(utterance: utterance, context: context))
                        self.recognizeNext()
                    }
                }
            } catch {
                self?.fail(session: session, message: error.localizedDescription)
            }
        }
        let capture = self.capture
        feedTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await buffer in feed.stream {
                    try Task.checkCancellation()
                    try await capture.consume(VoicePCMFrame(copying: buffer), session: session)
                }
                guard !Task.isCancelled else { return }
                await self?.fail(session: session, message: "The listening audio stopped. Resume hands-free voice to try again.")
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail(session: session, message: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let prior = id else { return }
        id = nil
        epoch = UUID()
        feedTask?.cancel(); feedTask = nil
        eventTask?.cancel(); eventTask = nil
        recognitionTask?.cancel(); recognitionTask = nil
        commandTask?.cancel(); commandTask = nil
        stopRepetition()
        for owner in owners.values {
            if let turn = owner.gate.token {
                owner.cancel(turn)
                Task { await owner.cancelCapture(turn) }
            }
        }
        owners = [:]; contexts = [:]; pending = []; finals = []
        memory = ConversationContext()
        Task { await capture.stop(session: prior) }
    }

    func isCurrent(_ command: ConversationCommand) -> Bool {
        id == command.session && epoch == command.epoch
    }

    private func fail(session: UUID, message: String) {
        guard id == session else { return }
        stop()
        onControl?(.stop)
        onEnded?(session, message)
    }

    private func recognizeNext() {
        guard recognitionTask == nil, let session = id else { return }
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.id == session { self.recognitionTask = nil } }
            while self.id == session, !Task.isCancelled, !self.pending.isEmpty {
                let pending = self.pending.removeFirst()
                let utterance = pending.utterance
                do {
                    guard let make = self.makeSpeechSession else { throw LocalSpeechError.unavailable }
                    let owner = try make(pending.context)
                    self.owners[utterance.id] = owner
                    let seconds = Double(utterance.samples.count) / 16_000
                    let deadline = utterance.sealedAt + min(8, max(2, 1.2 + seconds * 0.3))
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw LocalSpeechError.deadline }
                    let turn = try await owner.beginCapture(id: utterance.id, mode: .command,
                        now: utterance.detectedAt, previews: false, readyDeadline: deadline)
                    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                        sampleRate: 16_000, channels: 1, interleaved: false) else {
                        throw LocalSpeechError.captureLoss
                    }
                    var offset = 0, sequence = 0
                    while offset < utterance.samples.count {
                        guard self.id == session, !Task.isCancelled else { throw CancellationError() }
                        let count = min(16_000, utterance.samples.count - offset)
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                              let destination = buffer.floatChannelData?[0] else {
                            throw LocalSpeechError.captureLoss
                        }
                        buffer.frameLength = AVAudioFrameCount(count)
                        try utterance.samples.withUnsafeBufferPointer {
                            guard let source = $0.baseAddress else { throw LocalSpeechError.captureLoss }
                            destination.update(from: source.advanced(by: offset), count: count)
                        }
                        try await owner.consume(VoicePCMFrame(copying: buffer), sequence: sequence,
                                                turn: turn, retainRemote: false)
                        offset += count; sequence += 1
                    }
                    owner.context = self.readContext?() ?? VoiceAdmissionContext()
                    guard let admission = try await owner.finishCapture(turn, acceptedFrames: sequence,
                        releasedAt: utterance.sealedAt, capturedSeconds: seconds,
                        executeAutomatically: false, drain: {}),
                          self.id == session, !Task.isCancelled else { throw LocalSpeechError.stale }
                    self.onDiagnostic?(.init(turn: turn.id, stage: "conversation.final", metrics: [
                        "audio_samples": Double(utterance.samples.count),
                        "audio_start": Double(utterance.range.lowerBound),
                        "audio_end": Double(utterance.range.upperBound),
                        "endpoint_to_final_ms": (ProcessInfo.processInfo.systemUptime - utterance.sealedAt) * 1000]))
                    self.onEvent?(.final(turn.id, admission.text))
                    let localControl = ConversationContext.localControl(admission.text, after: self.previousFinal)
                    self.previousFinal = admission.text
                    if let control = localControl,
                       owner.consumeAdmission(turn) != nil {
                        await self.acknowledge(pending)
                        self.control(control, turn: turn.id)
                    } else if admission.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.onEvent?(.ignored(turn.id))
                        await self.acknowledge(pending)
                    } else {
                        self.finals.append(.init(pending: pending, owner: owner,
                                                admission: admission, epoch: self.epoch))
                        self.processNext()
                    }
                } catch {
                    guard self.id == session, !Task.isCancelled else { return }
                    self.fail(session: session, message: "Speech could not finish safely. " + error.localizedDescription)
                    return
                }
            }
        }
    }

    private func acknowledge(_ pending: Pending) async {
        owners.removeValue(forKey: pending.utterance.id)
        await capture.acknowledge(pending.utterance)
    }

    private func control(_ kind: ConversationDecision.Kind, turn: UUID) {
        epoch = UUID()
        commandTask?.cancel(); commandTask = nil
        stopRepetition()
        let discarded = finals
        finals = []
        for record in discarded {
            record.owner.cancel(record.admission.turn)
            Task { await acknowledge(record.pending) }
        }
        memory.discardFragment()
        onControl?(kind)
        onEvent?(.feedback(turn, kind == .pause ? "Hands-free voice is paused." : "Stopped."))
    }

    private func processNext() {
        guard commandTask == nil, let session = id else { return }
        let executionEpoch = epoch
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.id == session, self.epoch == executionEpoch { self.commandTask = nil }
            }
            while self.id == session, self.epoch == executionEpoch, !Task.isCancelled, !self.finals.isEmpty {
                let record = self.finals.removeFirst()
                do { try await self.process(record, session: session) }
                catch {
                    guard self.id == session, self.epoch == executionEpoch, !Task.isCancelled else {
                        await self.acknowledge(record.pending)
                        return
                    }
                    self.memory.discardFragment()
                    self.onEvent?(.feedback(record.admission.turn.id, error.localizedDescription))
                }
                await self.acknowledge(record.pending)
            }
        }
    }

    private func process(_ record: Final, session: UUID) async throws {
        let admission = record.admission
        guard record.epoch == epoch, record.owner.gate.isCurrent(admission.turn),
              let interpret, let execute, let readContext else { throw LocalSpeechError.stale }
        let text = try memory.combined(admission.text, context: record.pending.context)
        if ConversationContext.isNegativeFragment(text) {
            memory.hold(text, scope: .window(record.pending.context))
            onEvent?(.waiting(admission.turn.id))
            return
        }
        let policy = VoiceAdmissionPolicy.propose(text, context: record.pending.context, speech: true)
        guard policy.route != .refuse, policy.risk == .clear,
              policy.reason != "target_changed", policy.reason != "ask_changed" else {
            memory.discardFragment()
            onEvent?(.feedback(admission.turn.id, "Please restate the action you want me to take."))
            return
        }
        let capturedMemory = memory
        let decision = try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 8) {
            try await interpret(text, record.pending.context, capturedMemory)
        }
        guard id == session, record.epoch == epoch, !Task.isCancelled else { throw LocalSpeechError.stale }
        switch decision.kind {
        case .ignore:
            onEvent?(.ignored(admission.turn.id))
            return
        case .incomplete:
            memory.hold(text, scope: .window(record.pending.context))
            onEvent?(.waiting(admission.turn.id))
            return
        case .clarify:
            memory.discardFragment()
            onEvent?(.feedback(admission.turn.id, "Please clarify what you want me to do and where."))
            return
        case .stop, .pause:
            control(decision.kind, turn: admission.turn.id)
            return
        default: break
        }
        await beforeAction?()
        guard id == session, record.epoch == epoch, !Task.isCancelled else { throw LocalSpeechError.stale }
        if decision.kind == .answer {
            guard admission.intent == "respond", admission.route == .local,
                  let task = admission.slots["task_id"].flatMap(UUID.init(uuidString:)),
                  let ask = admission.slots["ask_id"].flatMap(UUID.init(uuidString:)),
                  readContext().currentAsks.contains(where: { $0.taskID == task && $0.askID == ask }) else {
                throw VoiceError("That question changed. Please answer the current question.")
            }
        } else {
            guard let scope = decision.scope, scope.matches(readContext()) else {
                throw VoiceError("The target changed while you were speaking. Please restate the request.")
            }
        }
        guard record.owner.consumeAdmission(admission.turn, resolvingClarification: true) != nil else {
            throw LocalSpeechError.stale
        }
        stopRepetition()
        if decision.kind == .continueScroll {
            guard let scroll = memory.scroll, decision.scope == scroll.scope else {
                throw VoiceError("There is no verified scroll to continue.")
            }
            let command = ConversationCommand(session: session, epoch: epoch, admission: admission,
                text: text, decision: decision, context: record.pending.context, continuation: scroll.viewport)
            repeatScroll(command, anchor: scroll)
            return
        }
        let goal: String
        if decision.windowScroll == nil, VoiceTaskCoordinator.isRepeatRequest(text) {
            guard memory.lastVerified, memory.lastScope == decision.scope, let previous = memory.lastGoal else {
                throw VoiceError("There is no verified request here to repeat. Please say the action.")
            }
            goal = previous
        } else { goal = text }
        if let scope = decision.scope {
            memory.remember(goal, scope: scope)
            memory.scroll = nil
        }
        let command = ConversationCommand(session: session, epoch: epoch, admission: admission,
            text: goal, decision: decision, context: record.pending.context, continuation: nil)
        let effect = try await execute(command)
        guard isCurrent(command), !Task.isCancelled else { throw LocalSpeechError.stale }
        accept(effect)
        if !effect.waitingForAnswer, !effect.message.isEmpty {
            onEvent?(.feedback(admission.turn.id, effect.message))
        }
    }

    private func accept(_ effect: ConversationEffect) {
        memory.recordVerification(effect.verified)
        guard effect.verified, let scroll = effect.scroll else { return }
        memory.scroll = .init(scope: .window(app: scroll.application, id: scroll.viewport.window.windowID),
                              direction: scroll.direction, small: scroll.lines == 1, viewport: scroll.viewport)
    }

    private func repeatScroll(_ request: ConversationCommand, anchor: ConversationContext.Scroll) {
        let repetition = UUID()
        repetitionID = repetition
        onEvent?(.scrolling(request.admission.turn.id, true))
        repetitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.repetitionID == repetition {
                    self.repetitionID = nil; self.repetitionTask = nil
                    self.onEvent?(.scrolling(request.admission.turn.id, false))
                }
            }
            do {
                guard let current = self.readContext?(), anchor.scope.matches(current),
                      let execute = self.execute else {
                    throw VoiceError("The scrolling target changed. Scrolling stopped.")
                }
                let effect = try await execute(request)
                guard self.isCurrent(request), self.repetitionID == repetition, !Task.isCancelled else { return }
                self.accept(effect)
                self.onEvent?(.feedback(request.admission.turn.id, effect.message))
            } catch {
                guard self.isCurrent(request), self.repetitionID == repetition, !Task.isCancelled else { return }
                self.onEvent?(.feedback(request.admission.turn.id, error.localizedDescription))
            }
        }
    }

    func recordScroll(_ scroll: NativeWindowObservation.VerifiedScroll, for command: ConversationCommand) {
        guard isCurrent(command), repetitionID != nil else { return }
        accept(.init(verified: true, waitingForAnswer: false, message: "", scroll: scroll))
    }

    private func stopRepetition() {
        if repetitionID != nil { onCancelRepetition?() }
        repetitionID = nil
        repetitionTask?.cancel(); repetitionTask = nil
    }
}

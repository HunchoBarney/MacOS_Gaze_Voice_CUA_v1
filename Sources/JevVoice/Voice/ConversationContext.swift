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
    var space: DesktopSpaceTarget?
    var local = false

    func matchesCurrentScope(_ current: VoiceAdmissionContext, captured: VoiceAdmissionContext, final: String) -> Bool {
        guard let scope, scope.matches(current) else { return false }
        if space != nil {
            return captured.desktopDisplayID == current.desktopDisplayID && current.currentAsks.isEmpty
        }
        if local, case .application(let entity) = scope {
            guard current.currentAsks.isEmpty else { return false }
            if captured.entities == current.entities { return true }
            let fresh = VoiceAdmissionPolicy.propose(final, context: current, speech: true)
            return fresh.route == .local && fresh.intent == "open" && fresh.slots["target_id"] == entity.id
        }
        return true
    }

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

    @MainActor
    func resolve(_ text: String, context: VoiceAdmissionContext, policy: VoiceProposal,
                 interpret: (String, VoiceAdmissionContext, ConversationContext) async throws -> ConversationDecision)
        async throws -> ConversationDecision {
        if let decision = localDecision(text, context: context, policy: policy) { return decision }
        return try await interpret(text, context, self)
    }

    @MainActor
    func localDecision(_ text: String, context: VoiceAdmissionContext,
                       policy: VoiceProposal) -> ConversationDecision? {
        guard policy.route != .refuse, policy.risk == .clear else { return nil }
        if policy.route == .local, policy.intent == "respond" {
            return .init(kind: .answer, local: true)
        }
        guard !text.contains(where: { "\"“”«»".contains($0) }) else { return nil }
        let command = VoiceAdmissionPolicy.commandText(text, context: context)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("'"), !trimmed.hasPrefix("‘"), !trimmed.hasPrefix("’") else { return nil }
        guard context.currentAsks.isEmpty, context.capturedAsks.isEmpty else { return nil }
        if policy.intent == "switch_space", policy.route == .local,
           let target = DesktopSpaceTarget(command: text) {
            guard let scope = ConversationScope.window(context) else { return .init(kind: .clarify, local: true) }
            return .init(kind: .task, scope: scope, space: target, local: true)
        }
        let normalized = VoiceAdmissionPolicy.normalized(command)
        if let scroll, scroll.scope.matches(context),
           case .window(let app, let window) = scroll.scope {
            if ["a little more", "a bit more", "a little further", "a bit further"].contains(normalized),
               let request = WindowScrollRequest(goal: text, application: app, windowID: window,
                    direction: scroll.direction, small: true, continuation: scroll.viewport) {
                return .init(kind: .scroll, scope: scroll.scope, direction: scroll.direction,
                             small: true, windowScroll: request, local: true)
            }
            if ["keep scrolling", "continue scrolling", "keep going",
                "okay keep scrolling", "ok keep scrolling"].contains(normalized) {
                return .init(kind: .continueScroll, scope: scroll.scope,
                             direction: scroll.direction, small: scroll.small, local: true)
            }
        }
        guard policy.route == .local else { return nil }
        if policy.intent == "open", let target = policy.slots["target_id"],
           let entity = context.entities.first(where: { $0.id == target && $0.canOpenLocally }),
           VoiceSemanticRouter.targetIsCurrent(entity, context: context) {
            return .init(kind: .task, scope: .application(entity), local: true)
        }
        guard let scope = ConversationScope.window(context),
              let parsed = FastAction.parse(command), parsed.appQualifier == nil else { return nil }
        switch parsed.action.body {
        case .scroll(let direction, let pages):
            let words = Set(normalized.split(separator: " ").map(String.init))
            guard pages == 1, words.isDisjoint(with: ["time", "times", "once"]),
                  !normalized.contains(where: \.isNumber),
                  let window = scope.windowID else { return nil }
            let small = normalized.hasSuffix("a little") || normalized.hasSuffix("a bit")
            guard let request = WindowScrollRequest(goal: text, application: scope.appID,
                windowID: window, direction: direction, small: small) else { return nil }
            return .init(kind: .scroll, scope: scope, direction: direction,
                         small: small, windowScroll: request, local: true)
        case .hotkey, .systemHotkey, .mediaKey:
            guard !normalized.hasPrefix("scroll ") else { return nil }
            return .init(kind: .task, scope: scope, local: true)
        default: return nil
        }
    }

    static func localControl(_ text: String) -> ConversationDecision.Kind? {
        switch HandsFreeActionSyntax.parse(text) {
        case .stop: return .stop
        case .pause: return .pause
        default: return nil
        }
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
        scroll = nil
    }

    mutating func recordVerification(_ verified: Bool) {
        lastVerified = verified
        if !verified { scroll = nil }
    }
    mutating func discardFragment() { fragment = nil; fragmentScope = nil }
    mutating func discardRequest() { self = Self() }

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
    case source(UUID, VoiceRealtimeInput)
    case sealed(UUID, TimeInterval)
    case final(UUID, String)
    case processing(UUID)
    case routed(UUID, local: Bool, startedAt: TimeInterval, endedAt: TimeInterval)
    case feedback(UUID, String)
    case literalRefusal(UUID, String)
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
        let utterance: ConversationUtterance
        let context: VoiceAdmissionContext
    }
    private struct Final: Sendable {
        let pending: Pending?
        let context: VoiceAdmissionContext
        let owner: LocalSpeechSession
        let admission: VoiceAdmission
        let epoch: UUID
    }

    struct RemoteCapture {
        let session: UUID
        let epoch: UUID
        let input: VoiceRealtimeInput
        let owner: LocalSpeechSession
        let turn: VoiceTurnToken
        let context: VoiceAdmissionContext
    }

    typealias RemoteExecutor = @MainActor () async throws -> ConversationEffect?
    var remote: ((VoiceAdmission, LocalSpeechSession, @escaping RemoteExecutor) async throws -> Void)?
    var controlQuestion: ((VoiceAdmission, LocalSpeechSession, Bool, @escaping @MainActor () -> Bool) async -> Void)?
    var localStatusQuestion: ((VoiceAdmission, LocalSpeechSession, @escaping @MainActor () -> Bool) async -> Bool)?
    private var latestInput: UUID?
    private var literalTarget: SpokenLiteralTarget? {
        didSet { if literalTarget == nil { literalExpiry?.cancel(); literalExpiry = nil } }
    }
    private var literalExpiry: Task<Void, Never>?
    var captureLiteralTarget: ((String, Int) -> SpokenLiteralTarget?)?
    var literalInputPermitted: ((VoiceRealtimeInput) -> Bool)?
    private let capture: (any ConversationSegmenter)?
    var makeSpeechSession: ((VoiceAdmissionContext) throws -> LocalSpeechSession)?
    var readContext: (() -> VoiceAdmissionContext)?
    var spokenGazeClick: ((VoiceAdmission, LocalSpeechSession, @escaping @MainActor @Sendable () -> Bool) async -> Bool)?
    var readPendingAsks: (() -> [VoiceAdmissionContext.Ask])?
    var interpret: (@MainActor @Sendable (String, VoiceAdmissionContext, ConversationContext) async throws -> ConversationDecision)?
    var execute: ((ConversationCommand) async throws -> ConversationEffect)?
    var beforeAction: (() async -> Void)?
    var onControl: ((ConversationDecision.Kind) -> Void)?
    var pendingDesktopEffect: (() -> String?)?
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
    private var external = false

    private let literalOnly: Bool

    init(capture: (any ConversationSegmenter)? = nil, literalOnly: Bool = false) {
        self.capture = capture
        self.literalOnly = literalOnly
    }

    private func diagnosticCapture() throws -> any ConversationSegmenter {
        guard let capture else { throw VoiceError("No diagnostic conversation segmenter was supplied.") }
        return capture
    }

    func prepare() async throws { try await diagnosticCapture().prepare() }

    func startExternal(session: UUID) throws {
        guard id == nil, makeSpeechSession != nil, readContext != nil,
              literalOnly || (interpret != nil && execute != nil), onControl != nil else {
            throw VoiceError("Hands-free voice is not ready.")
        }
        id = session
        epoch = UUID()
        memory = ConversationContext()
        previousFinal = nil
        external = true
    }

    func beginExternal(input: VoiceRealtimeInput, at detectedAt: TimeInterval, gazeClickLease: UUID? = nil) throws -> RemoteCapture {
        guard external, let session = id, let context = readContext?(), let make = makeSpeechSession else {
            throw CancellationError()
        }
        let owner = try make(context)
        let turn = owner.beginRemoteCapture(id: UUID(), mode: .command,
                                           connection: input.connectionID, now: detectedAt, gazeClickLease: gazeClickLease)
        owners[turn.id] = owner
        latestInput = turn.id
        literalTarget = nil
        if context.capturedAsks.isEmpty, context.currentAsks.isEmpty, literalInputPermitted?(input) == true,
           let app = context.targetAppID, !literalOnly || app == "com.apple.TextEdit", let window = context.windowID {
            literalTarget = captureLiteralTarget?(app, window)
            if literalTarget != nil {
                literalExpiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if self?.latestInput == turn.id { self?.literalTarget = nil }
                }
            }
        }
        stopRepetition()
        onBargeIn?()
        onEvent?(.began(turn.id, detectedAt))
        onEvent?(.source(turn.id, input))
        return .init(session: session, epoch: epoch, input: input,
                     owner: owner, turn: turn, context: context)
    }

    func commitExternal(_ record: RemoteCapture, at sealedAt: TimeInterval) -> Bool {
        guard id == record.session, epoch == record.epoch,
              record.owner.commitRemoteCapture(record.turn, input: record.input, now: sealedAt) else { return false }
        onEvent?(.sealed(record.turn.id, sealedAt))
        return true
    }

    func discardExternal(_ record: RemoteCapture) {
        if latestInput == record.turn.id { literalTarget = nil }
        record.owner.cancel(record.turn)
        owners.removeValue(forKey: record.turn.id)
        if id == record.session, epoch == record.epoch { onEvent?(.ignored(record.turn.id)) }
    }

    func finishExternal(_ record: RemoteCapture, text: String, at now: TimeInterval, gazeClickLease: UUID? = nil) async {
        guard id == record.session, epoch == record.epoch,
              record.owner.gate.state == .finishing else { return }
        record.owner.context = readContext?() ?? VoiceAdmissionContext()
        guard let admission = await record.owner.finishRemoteCapture(text, turn: record.turn,
            input: record.input, now: now, gazeClickLease: gazeClickLease) else {
            traceBoundary(.admissionRejected, turn: record.turn.id)
            discardExternal(record)
            return
        }
        guard id == record.session, epoch == record.epoch, !Task.isCancelled else { return }
        onEvent?(literalOnly ? .processing(record.turn.id) : .final(record.turn.id, admission.text))
#if DEBUG
        if !literalOnly, await record.owner.consumeReservedFixture(record.turn, input: record.input, current: { [weak self] in
            self?.id == record.session && self?.epoch == record.epoch && self?.latestInput == record.turn.id
                && self?.fixtureInputIsCurrent?(record.input) == true
        }) {
            owners.removeValue(forKey: record.turn.id)
            return
        }
#endif
        let localControl = ConversationContext.localControl(admission.text, after: previousFinal)
        previousFinal = admission.text
        if admission.intent == "conversation_control", let localControl, record.owner.consumeAdmission(record.turn) != nil {
            owners.removeValue(forKey: record.turn.id)
            control(localControl, turn: record.turn.id)
            return
        }
        finals.append(.init(pending: nil, context: record.context, owner: record.owner,
                            admission: admission, epoch: record.epoch))
        processNext()
    }

#if DEBUG
    var fixtureInputIsCurrent: ((VoiceRealtimeInput) -> Bool)?
#endif

    func start(feed: ConvertedAudioFeed, session: UUID) async throws {
        let capture = try diagnosticCapture()
        guard id == nil, makeSpeechSession != nil, readContext != nil,
              interpret != nil, execute != nil, onControl != nil else {
            throw VoiceError("Hands-free voice is not ready.")
        }
        let stream = try await capture.begin(session: session)
        try Task.checkCancellation()
        id = session
        external = false
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
                        self.stopRepetition()
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
        literalTarget = nil
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
        if !external, let capture { Task { await capture.stop(session: prior) } }
    }

    func cancelExternalWork() {
        guard external, id != nil else { return }
        epoch = UUID()
        literalTarget = nil
        commandTask?.cancel(); commandTask = nil
        stopRepetition()
        for owner in owners.values {
            if let turn = owner.gate.token { owner.cancel(turn) }
        }
        owners = [:]; finals = []
        previousFinal = nil
        memory = ConversationContext()
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
                    if admission.intent == "conversation_control", let control = localControl,
                       owner.consumeAdmission(turn) != nil {
                        await self.acknowledge(pending)
                        self.control(control, turn: turn.id)
                    } else if admission.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.onEvent?(.ignored(turn.id))
                        await self.acknowledge(pending)
                    } else {
                        self.finals.append(.init(pending: pending, context: pending.context, owner: owner,
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
        await capture?.acknowledge(pending.utterance)
    }

    private func acknowledge(_ record: Final) async {
        if latestInput == record.admission.turn.id { literalTarget = nil }
        owners.removeValue(forKey: record.admission.turn.id)
        if let pending = record.pending { await capture?.acknowledge(pending.utterance) }
    }

    private func control(_ kind: ConversationDecision.Kind, turn: UUID) {
        epoch = UUID()
        commandTask?.cancel(); commandTask = nil
        stopRepetition()
        let discarded = finals
        finals = []
        for record in discarded {
            record.owner.cancel(record.admission.turn)
            Task { await acknowledge(record) }
        }
        memory.discardFragment()
        let desktopEffect = literalOnly ? nil : pendingDesktopEffect?()
        onControl?(kind)
        let message = kind == .pause ? "Hands-free voice is paused." : "Stopped."
        onEvent?(.feedback(turn, message + (desktopEffect.map { " " + $0 } ?? "")))
    }

    private func reportLiteralRefusal(_ turn: UUID, _ message: String) {
        onEvent?(literalOnly ? .literalRefusal(turn, message) : .feedback(turn, message))
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
                do { _ = try await self.process(record, session: session) }
                catch {
                    guard self.id == session, self.epoch == executionEpoch, !Task.isCancelled else {
                        await self.acknowledge(record)
                        return
                    }
                    self.memory.discardRequest()
                    self.onEvent?(.feedback(record.admission.turn.id, error.localizedDescription))
                }
                await self.acknowledge(record)
            }
        }
    }

    private func process(_ record: Final, session: UUID, allowRemote: Bool = true,
                         priorMemory: ConversationContext? = nil) async throws -> ConversationEffect? {
        let admission = record.admission
        guard record.epoch == epoch, record.owner.gate.isCurrent(admission.turn),
              literalOnly || (interpret != nil && execute != nil), let readContext else { throw LocalSpeechError.stale }
        let resolutionMemory = priorMemory ?? memory
        let literalCommand = HandsFreeActionSyntax.withoutCourtesy(admission.text)
        if let input = admission.realtimeInput, record.pending == nil, admission.turn.mode == .command,
           admission.intent != "respond", admission.reason != "unbound_pointing",
           VoiceAdmissionPolicy.isSpokenTypeRequest(literalCommand) {
            func current(_ state: VoiceTurnGate.State) -> Bool {
                id == session && epoch == record.epoch && latestInput == admission.turn.id && !Task.isCancelled
                    && record.owner.gate.isCurrent(admission.turn) && record.owner.gate.state == state && record.owner.gate.realtimeInput == input
                    && literalInputPermitted?(input) == true && readPendingAsks?().isEmpty == true
            }
            guard latestInput == admission.turn.id else { return nil }
            let target = literalTarget
            literalTarget = nil
            memory.discardRequest()
            traceBoundary(admission.route == .local && admission.intent == "type" ? .localType : .otherAdmission, turn: admission.turn.id)
            traceBoundary(target == nil ? .fieldMissing : .fieldBound, turn: admission.turn.id)
            guard resolutionMemory.fragment == nil, record.context.capturedAsks.isEmpty,
                  record.context.currentAsks.isEmpty, current(.admitted),
                  let text = VoiceAdmissionPolicy.standaloneLiteral(literalCommand, admission: admission),
                  let target, record.owner.consumeAdmission(admission.turn) != nil,
                  await DictationDelivery.sharedLease.tryAcquire() else {
                traceBoundary(.executionRejected, turn: admission.turn.id)
                if id == session, epoch == record.epoch, latestInput == admission.turn.id {
                    reportLiteralRefusal(admission.turn.id, "No text was sent. Focus one field and say “type” followed by the text. Quote anything that could be a second instruction.")
                }
                return nil
            }
            let result = target.insert(text) { current(.completed) }
            if result != .notSent { traceBoundary(.nativeAttempt, turn: admission.turn.id) }
            traceBoundary(result == .verified ? .nativeExact : result == .unverified ? .unverified : .executionRejected, turn: admission.turn.id)
            await DictationDelivery.sharedLease.release()
            guard id == session, epoch == record.epoch, latestInput == admission.turn.id else { return nil }
            switch result {
            case .verified: onEvent?(.feedback(admission.turn.id, "Typed the text."))
            case .notSent: reportLiteralRefusal(admission.turn.id, "The typing target wasn’t available. No text was sent.")
            case .unverified: reportLiteralRefusal(admission.turn.id, "I couldn’t verify the insertion. Check the field before trying again.")
            }
            return nil
        }
        if literalOnly {
            memory.discardRequest()
            reportLiteralRefusal(admission.turn.id, "No text was sent. This profile only types a literal into TextEdit.")
            return nil
        }
        guard let interpret, let execute else { throw LocalSpeechError.stale }
        if admission.realtimeInput != nil, admission.turn.mode == .command, admission.intent != "respond",
           VoiceAdmissionPolicy.isBareGazeClick(admission.text) {
            let standalone = resolutionMemory.fragment == nil
            memory.discardRequest()
            let current: @MainActor @Sendable () -> Bool = { [weak self] in
                self?.id == session && self?.epoch == record.epoch && self?.latestInput == admission.turn.id
            }
            if standalone, record.pending == nil,
               await spokenGazeClick?(admission, record.owner, current) == true { return nil }
            if current() { onEvent?(.ignored(admission.turn.id)) }
            return nil
        }
        if admission.isLocalStatusQuestion {
            let standalone = resolutionMemory.fragment == nil
            memory.discardRequest()
            let current = { @MainActor [weak self] in
                self?.id == session && self?.epoch == record.epoch && self?.latestInput == admission.turn.id
            }
            if standalone, record.pending == nil,
               await localStatusQuestion?(admission, record.owner, current) == true { return nil }
            if current() { onEvent?(.ignored(admission.turn.id)) }
            return nil
        }
        if admission.reason == "unbound_pointing" {
            memory.discardRequest()
            onEvent?(.feedback(admission.turn.id, "Please name the control you want to use."))
            return nil
        }
        if admission.route == .clarify, admission.reason == "ambiguous_ask" {
            memory.discardRequest()
            onEvent?(.waiting(admission.turn.id))
            return nil
        }
        if admission.intent == "screen_question" || ScreenQuestionObservation.isScreenInquiry(admission.text, context: record.context) {
            let standalone = resolutionMemory.fragment == nil
            memory.discardRequest()
            await controlQuestion?(admission, record.owner, standalone) { [weak self] in
                self?.id == session && self?.epoch == record.epoch
                    && (record.pending != nil || self?.latestInput == admission.turn.id)
            }
            return nil
        }
        let text = try resolutionMemory.combined(admission.text, context: record.context)
        if ConversationContext.isNegativeFragment(text) {
            memory.hold(text, scope: .window(record.context))
            onEvent?(.waiting(admission.turn.id))
            return nil
        }
        var refreshedContext = record.context
        refreshedContext.currentAsks = readPendingAsks?() ?? readContext().currentAsks
        let currentContext = refreshedContext
        let policy = VoiceAdmissionPolicy.propose(text, context: currentContext, speech: true)
        let boundClickReply = admission.intent == "respond" && VoiceAdmissionPolicy.isBareGazeClick(admission.text)
        if boundClickReply || policy.reason == "unbound_pointing"
            || FastAction.retiredTargetRequest(admission.text) != nil || FastAction.retiredTargetRequest(text) != nil,
           policy.intent != "respond" || admission.intent != "respond" || text != admission.text {
            memory.discardRequest()
            onEvent?(.feedback(admission.turn.id, "Please name the control you want to use."))
            return nil
        }
        let syntax = HandsFreeActionSyntax.parse(text)
        let protected = syntax == .nonAction || syntax == .space(.next) || syntax == .space(.previous)
        let appLostAuthority = admission.intent == "open" && admission.route == .local
            && (!currentContext.currentAsks.isEmpty || !currentContext.capturedAsks.isEmpty)
        guard !protected || policy.intent == "respond" || policy.intent == "type",
              !appLostAuthority,
              policy.route != .refuse, policy.risk == .clear,
              !["target_changed", "ask_changed", "ambiguous_target"].contains(admission.reason),
              !["target_changed", "ask_changed", "ambiguous_target"].contains(policy.reason) else {
            memory.discardRequest()
            onEvent?(.feedback(admission.turn.id, "Please restate the action you want me to take."))
            return nil
        }
        let capturedMemory = resolutionMemory
        let routeStarted = ProcessInfo.processInfo.systemUptime
        if allowRemote, admission.route == .remote,
           capturedMemory.localDecision(text, context: currentContext, policy: policy) == nil,
           let remote {
            memory.discardRequest()
            onEvent?(.routed(admission.turn.id, local: false, startedAt: routeStarted,
                            endedAt: ProcessInfo.processInfo.systemUptime))
            try await remote(admission, record.owner) { [weak self] in
                guard let self, self.id == session, record.epoch == self.epoch else { throw CancellationError() }
                return try await self.process(record, session: session, allowRemote: false,
                                              priorMemory: capturedMemory)
            }
            return nil
        }
        let decision = try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 8) {
            try await capturedMemory.resolve(text, context: currentContext, policy: policy, interpret: interpret)
        }
        guard id == session, record.epoch == epoch, !Task.isCancelled else { throw LocalSpeechError.stale }
        onEvent?(.routed(admission.turn.id, local: decision.local, startedAt: routeStarted,
                        endedAt: ProcessInfo.processInfo.systemUptime))
        switch decision.kind {
        case .ignore:
            onEvent?(.ignored(admission.turn.id))
            return nil
        case .incomplete:
            memory.hold(text, scope: .window(record.context))
            onEvent?(.waiting(admission.turn.id))
            return nil
        case .clarify:
            memory.discardRequest()
            onEvent?(.feedback(admission.turn.id, "Please clarify what you want me to do and where."))
            return nil
        case .stop, .pause:
            memory.discardRequest()
            onEvent?(.feedback(admission.turn.id, "Say stop or pause listening to interrupt."))
            return nil
        default: break
        }
        await beforeAction?()
        guard id == session, record.epoch == epoch, !Task.isCancelled else { throw LocalSpeechError.stale }
        if decision.kind == .answer {
            let liveAsks = readPendingAsks?() ?? readContext().currentAsks
            if boundClickReply || FastAction.retiredTargetRequest(admission.text) != nil {
                var fresh = record.context
                fresh.currentAsks = liveAsks
                guard VoiceAdmissionPolicy.propose(admission.text, context: fresh, speech: true).intent == "respond" else {
                    throw VoiceError("That question changed. Please answer the current question.")
                }
            }
            guard admission.intent == "respond", admission.route == .local,
                  let task = admission.slots["task_id"].flatMap(UUID.init(uuidString:)),
                  let ask = admission.slots["ask_id"].flatMap(UUID.init(uuidString:)),
                  liveAsks.contains(where: {
                      $0.taskID == task && $0.askID == ask
                  }) else {
                throw VoiceError("That question changed. Please answer the current question.")
            }
        } else {
            guard decision.matchesCurrentScope(readContext(), captured: record.context, final: admission.text) else {
                throw VoiceError("The target changed while you were speaking. Please restate the request.")
            }
        }
        guard record.owner.consumeAdmission(admission.turn, resolvingClarification: true) != nil else {
            throw LocalSpeechError.stale
        }
        stopRepetition()
        if decision.kind == .continueScroll {
            guard let scroll = capturedMemory.scroll, decision.scope == scroll.scope else {
                throw VoiceError("There is no verified scroll to continue.")
            }
            let command = ConversationCommand(session: session, epoch: epoch, admission: admission,
                text: text, decision: decision, context: record.context, continuation: scroll.viewport)
            repeatScroll(command, anchor: scroll)
            return .init(verified: false, waitingForAnswer: false, message: "Starting the scroll.")
        }
        let goal: String
        if decision.windowScroll == nil, VoiceTaskCoordinator.isRepeatRequest(text) {
            guard capturedMemory.lastVerified, capturedMemory.lastScope == decision.scope,
                  let previous = capturedMemory.lastGoal else {
                throw VoiceError("There is no verified request here to repeat. Please say the action.")
            }
            goal = previous
        } else { goal = text }
        if let scope = decision.scope {
            memory.remember(goal, scope: scope)
        } else {
            memory.discardRequest()
        }
        let command = ConversationCommand(session: session, epoch: epoch, admission: admission,
            text: goal, decision: decision, context: record.context, continuation: nil)
        let effect = try await execute(command)
        guard isCurrent(command), !Task.isCancelled else { throw LocalSpeechError.stale }
        accept(effect)
        if allowRemote, !effect.waitingForAnswer, !effect.message.isEmpty {
            onEvent?(.feedback(admission.turn.id, effect.message))
        }
        return effect
    }

    private func accept(_ effect: ConversationEffect) {
        memory.recordVerification(effect.verified)
        guard effect.verified, let scroll = effect.scroll else {
            memory.scroll = nil
            return
        }
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

    private func traceBoundary(_ stage: NoFnTrace.Stage, turn: UUID? = nil) {
        if !literalOnly { NoFnTrace.mark(stage, turn: turn) }
    }

    private func stopRepetition() {
        if repetitionID != nil { onCancelRepetition?() }
        repetitionID = nil
        repetitionTask?.cancel(); repetitionTask = nil
    }
}

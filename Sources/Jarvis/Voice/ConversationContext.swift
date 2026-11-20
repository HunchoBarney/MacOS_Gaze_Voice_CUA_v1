import AVFoundation
import Foundation
import JarvisCore

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
    var local = false

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
        guard policy.route != .refuse, policy.risk == .clear,
              !text.contains(where: { "\"“”«»".contains($0) }) else { return nil }
        let command = VoiceAdmissionPolicy.commandText(text, context: context)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("'"), !trimmed.hasPrefix("‘"), !trimmed.hasPrefix("’") else { return nil }
        if policy.route == .local, policy.intent == "respond" {
            return .init(kind: .answer, local: true)
        }
        guard context.currentAsks.isEmpty, context.capturedAsks.isEmpty else { return nil }
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
    case off, preparing, listening, standby, paused, unavailable(String)
}

enum ConversationPresentation {
    case began(UUID, TimeInterval)
    case sealed(UUID, TimeInterval)
    case final(UUID, String)
    case routed(UUID, local: Bool, startedAt: TimeInterval, endedAt: TimeInterval)
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
    private struct Final: Sendable {
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
    private var finals: [Final] = []
    private var owners: [UUID: LocalSpeechSession] = [:]
    private var memory = ConversationContext()
    private var commandTask: Task<Void, Never>?
    private var repetitionTask: Task<Void, Never>?
    private var repetitionID: UUID?
    private var previousFinal: String?

    func startExternal(session: UUID) throws {
        guard id == nil, makeSpeechSession != nil, readContext != nil,
              interpret != nil, execute != nil, onControl != nil else {
            throw VoiceError("I'm not ready to listen yet.")
        }
        id = session
        epoch = UUID()
        memory = ConversationContext()
        previousFinal = nil
    }

    func beginExternal(input: VoiceRealtimeInput, at detectedAt: TimeInterval) throws -> RemoteCapture {
        guard let session = id, let context = readContext?(), let make = makeSpeechSession else {
            throw CancellationError()
        }
        let owner = try make(context)
        let turn = owner.beginRemoteCapture(id: UUID(), mode: .command,
                                           connection: input.connectionID, now: detectedAt)
        owners[turn.id] = owner
        stopRepetition()
        onBargeIn?()
        onEvent?(.began(turn.id, detectedAt))
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
        record.owner.cancel(record.turn)
        owners.removeValue(forKey: record.turn.id)
        if id == record.session, epoch == record.epoch { onEvent?(.ignored(record.turn.id)) }
    }

    func finishExternal(_ record: RemoteCapture, text: String, at now: TimeInterval) async {
        guard id == record.session, epoch == record.epoch,
              record.owner.gate.state == .finishing else { return }
        record.owner.context = readContext?() ?? VoiceAdmissionContext()
        guard let admission = await record.owner.finishRemoteCapture(text, turn: record.turn,
            input: record.input, now: now) else {
            discardExternal(record)
            return
        }
        guard id == record.session, epoch == record.epoch, !Task.isCancelled else { return }
        onEvent?(.final(record.turn.id, admission.text))
        let localControl = ConversationContext.localControl(admission.text, after: previousFinal)
        previousFinal = admission.text
        if let localControl, record.owner.consumeAdmission(record.turn) != nil {
            owners.removeValue(forKey: record.turn.id)
            control(localControl, turn: record.turn.id)
            return
        }
        finals.append(.init(context: record.context, owner: record.owner,
                            admission: admission, epoch: record.epoch))
        processNext()
    }

    func stop() {
        guard id != nil else { return }
        id = nil
        epoch = UUID()
        commandTask?.cancel(); commandTask = nil
        stopRepetition()
        for owner in owners.values {
            if let turn = owner.gate.token {
                owner.cancel(turn)
                Task { await owner.cancelCapture(turn) }
            }
        }
        owners = [:]; finals = []
        memory = ConversationContext()
    }

    func cancelExternalWork() {
        guard id != nil else { return }
        epoch = UUID()
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

    private func acknowledge(_ record: Final) {
        owners.removeValue(forKey: record.admission.turn.id)
    }

    private func control(_ kind: ConversationDecision.Kind, turn: UUID) {
        epoch = UUID()
        commandTask?.cancel(); commandTask = nil
        stopRepetition()
        let discarded = finals
        finals = []
        for record in discarded {
            record.owner.cancel(record.admission.turn)
            acknowledge(record)
        }
        memory.discardFragment()
        onControl?(kind)
        onEvent?(.feedback(turn, kind == .pause ? "Okay, I'll stop listening. Press fn when you need me." : "Stopped."))
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
                        self.acknowledge(record)
                        return
                    }
                    self.memory.discardRequest()
                    self.onEvent?(.feedback(record.admission.turn.id, error.localizedDescription))
                }
                self.acknowledge(record)
            }
        }
    }

    private func process(_ record: Final, session: UUID, allowRemote: Bool = true,
                         priorMemory: ConversationContext? = nil) async throws -> ConversationEffect? {
        let admission = record.admission
        guard record.epoch == epoch, record.owner.gate.isCurrent(admission.turn),
              let interpret, let execute, let readContext else { throw LocalSpeechError.stale }
        let resolutionMemory = priorMemory ?? memory
        let text = try resolutionMemory.combined(admission.text, context: record.context)
        if ConversationContext.isNegativeFragment(text) {
            memory.hold(text, scope: .window(record.context))
            onEvent?(.waiting(admission.turn.id))
            return nil
        }
        var refreshedContext = record.context
        refreshedContext.currentAsks = readContext().currentAsks
        let currentContext = refreshedContext
        let policy = VoiceAdmissionPolicy.propose(text, context: currentContext, speech: true)
        guard policy.route != .refuse, policy.risk == .clear,
              policy.reason != "target_changed", policy.reason != "ask_changed" else {
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
            control(decision.kind, turn: admission.turn.id)
            return nil
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

    private func stopRepetition() {
        if repetitionID != nil { onCancelRepetition?() }
        repetitionID = nil
        repetitionTask?.cancel(); repetitionTask = nil
    }
}

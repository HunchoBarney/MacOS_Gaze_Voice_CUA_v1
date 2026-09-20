import AppKit
import Combine
import JevVoiceCore

struct VoiceTimings {
    var finalization: TimeInterval = 2
    var warning: TimeInterval = 50
    var limit: TimeInterval = 55
    var dismissal: TimeInterval = 1.5
    var stabilization: TimeInterval = 0.30
}

@MainActor
final class VoiceController: ObservableObject {
    enum Status: Equatable {
        case idle, starting, listening, finishing, awaitingRelease, reviewTranscript
        case thinking, awaitingConfirm, executing, stopping, testingMicrophone, done
        case error(String)
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var decisions: [Decision] = []
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var model = ""
    @Published private(set) var history: [Decision] = []
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var inputName = ""
    @Published private(set) var detail = ""
    @Published private(set) var resultMessage = ""
    @Published private(set) var measurements: [String: Double] = [:]
    @Published private(set) var isMicrophoneTest = false
    @Published var missingPermissions: [Permission] = Permission.missing

    let config: Config
    private(set) var cua: CuaVoiceRuntime?
    var cuaTasks: [CuaVoiceRuntime.Work] { cua?.tasks ?? [] }
    var diagnosticTask: CuaVoiceRuntime.Work? { cuaTasks.first { $0.id == cua?.selectedID } }
    func stopAll() { cancel(); cua?.stopAll() }
    func selectTask(_ id: UUID) { cua?.select(id) }
    func cancelTask(_ id: UUID) { cua?.cancel(id) }
    func approveTask(_ id: UUID, approved: Bool) { cua?.resolveApproval(id, approved: approved) }
    var pendingTaskApproval: CuaVoiceRuntime.Work? { cuaTasks.first(where: { $0.approval != nil }) }
    private let speech: SpeechCapturing
    private let authorize: () async -> Bool
    private let interpret: (String, String?) async throws -> [Decision]
    private let execute: (Decision) async throws -> String
    private let undo: () async throws -> String
    private let beginNative: (String?) -> Void
    private let installedApps: [String]
    private let timings: VoiceTimings
    private let frontmost: () -> String?
    private var appObserver: AnyCancellable?
    private var lastExternalApp: String?
    private var commandFrontmostApp: String?
    private var sessionID: UUID?
    private var held = false
    private var automatic = true
    private var startupTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var beganAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    private var completedActions = 0
    private var stream = IncrementalCommandCoordinator()
    private var streamRevision = 0
    private var readyRevision = -1
    private var actionEpoch = 0
    private var streamFinal = false
    private var streamSuspended = false
    private var pendingControl: IncrementalCommandCoordinator.Candidate?
    private var controlReversesLaunch = false
    private var stabilizationTask: Task<Void, Never>?
    private var stabilizingCommand: String?
    private var interpretationTask: Task<[Decision], Error>?
    private var lastStreamResult = ""
    private var lastStreamFailure: String?
    private var reviewAfterOperation = false
    private var eligibleAt: TimeInterval = 0
    private var correctionAt: TimeInterval = 0
    private let resolvedTarget: () -> String?
    private let updateDictation: (Decision) async throws -> Bool
    private var liveDictationActive = false
    private var liveDictationDeferred = false


    var isListening: Bool { status == .listening }
    var canBegin: Bool {
        if let cua, !held, !cua.speech.busy, cleanupTask == nil, startupTask == nil,
           [.executing, .thinking].contains(status) { return true }
        if isMicrophoneTest && status != .stopping { return true }
        switch status { case .idle, .done, .error: return cleanupTask == nil && operationTask == nil; default: return false }
    }
    var operationActive: Bool {
        if cua?.active == true { return true }
        switch status { case .idle, .done, .error: return false; default: return true }
    }
    var captureActive: Bool { status == .starting || status == .listening || status == .awaitingRelease || status == .testingMicrophone }

    init(config: Config? = nil, speech: SpeechCapturing? = nil,
         authorize: (() async -> Bool)? = nil,
         interpret: ((String, String?) async throws -> [Decision])? = nil,
         execute: ((Decision) async throws -> String)? = nil,
         timings: VoiceTimings = VoiceTimings(), frontmost: (() -> String?)? = nil,
         undo: (() async throws -> String)? = nil, installedApps: [String]? = nil,
         resolvedTarget: (() -> String?)? = nil,
         updateDictation: ((Decision) async throws -> Bool)? = nil,
         cuaRuntime: CuaVoiceRuntime? = nil) {
        let config = config ?? Config.shared
        self.config = config
        self.speech = speech ?? SpeechAnalyzerCapture()
        self.authorize = authorize ?? { await SpeechAnalyzerCapture.requestAuthorization() }
        // Injected legacy seams remain only for migration regression comparison.
        // Production always uses Cua; no failure can select the native executor.
        let productionCua = interpret == nil && execute == nil
        self.cua = cuaRuntime ?? (productionCua ? CuaVoiceRuntime(config: config) : nil)
        let native = !productionCua && execute == nil ? NativeAppActions() : nil
        self.execute = execute ?? { guard let native else { throw DriverConnectionError.refused("Legacy execution is disabled.") }; return try await native.execute($0) }
        self.undo = undo ?? { guard let native else { throw ExecutorError.controlFailed("The last action cannot be reversed.") }; return try await native.undoLaunch() }
        self.beginNative = { native?.begin(context: $0) }
        self.resolvedTarget = resolvedTarget ?? { native?.resolvedTargetName }
        self.updateDictation = updateDictation ?? { try await native?.updateDictation($0) ?? false }
        let apps = installedApps ?? (productionCua ? [] : InstalledApps.all())
        self.installedApps = apps
        self.timings = timings
        self.frontmost = frontmost ?? { NSWorkspace.shared.frontmostApplication?.localizedName }
        self.interpret = interpret ?? { text, app in
            let interpreter = CommandInterpreter(client: JevClient(apiKey: config.apiKey), installedApps: apps)
            return try await interpreter.interpret(transcript: text, frontmostApp: app)
        }
        lastExternalApp = self.frontmost()
        appObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastExternalApp = $0.localizedName }
        self.cua?.onChange = { [weak self] in self?.cuaChanged() }
        self.speech.onEvent = { [weak self] id, event in self?.receive(event, session: id) }
    }

    func refreshPermissions() { missingPermissions = Permission.missing }

    func showSetup(_ message: String) {
        guard !operationActive else { return }
        fail(message)
    }
    func begin(inputHandlingMs: Double? = nil) {
        guard canBegin else { return }
        let priorStart = startupTask
        priorStart?.cancel()
        speech.cancel()
        isMicrophoneTest = false
        held = true
        let id = newSession()
        if let inputHandlingMs { measurements["Fn handler"] = inputHandlingMs }
        commandFrontmostApp = lastExternalApp
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            commandFrontmostApp = frontmost() ?? lastExternalApp
        }
        beginNative(commandFrontmostApp)
        cua?.begin(app: commandFrontmostApp)
        status = .starting
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            await priorStart?.value
            guard let self, self.sessionID == id, !Task.isCancelled else { return }
            defer { if self.sessionID == id { self.startupTask = nil } }
            let permissionStart = ProcessInfo.processInfo.systemUptime
            let granted = await self.authorize()
            self.refreshPermissions()
            guard self.sessionID == id, self.held, !Task.isCancelled else { return }
            self.measurements["Permission check"] = (ProcessInfo.processInfo.systemUptime - permissionStart) * 1000
            guard granted else { self.fail("Microphone access is needed. Open Voice settings."); return }
            do {
                let name = try await self.speech.start(session: id, inputUID: selectedUID, transcribe: true)
                guard self.sessionID == id, self.held, !Task.isCancelled else { return }
                self.inputName = name
                self.measurements["Microphone ready"] = (ProcessInfo.processInfo.systemUptime - self.beganAt) * 1000
                if self.status == .starting { self.status = .listening }
                self.scheduleDuration(id)
            } catch {
                if self.sessionID == id, !Task.isCancelled { self.fail(error.localizedDescription) }
            }
        }
    }

    func finish() {
        held = false
        durationTask?.cancel(); durationTask = nil
        switch status {
        case .starting: cancel()
        case .awaitingRelease: showTranscriptReview()
        case .listening:
            stabilizationTask?.cancel(); interpretationTask?.cancel()
            streamRevision += 1; readyRevision = -1
            releasedAt = ProcessInfo.processInfo.systemUptime
            status = .finishing
            audioLevel = 0
            speech.finish()
            guard let id = sessionID, status == .finishing else { return }
            deadlineTask = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: UInt64(self.timings.finalization * 1e9)) } catch { return }
                guard self.sessionID == id, self.status == .finishing else { return }
                self.speech.cancel()
                self.detail = "Speech didn't finish in time. Review the captured text before continuing."
                self.showTranscriptReview()
            }
        default: break
        }
    }

    func acceptTranscript() {
        guard status == .reviewTranscript, operationTask == nil, let id = sessionID else { return }
        submit(transcript, session: id)
    }

    func confirm() {
        guard status == .awaitingConfirm, let id = sessionID, operationTask == nil else { return }
        if let cua { status = .executing; cua.update(transcript, final: true); return }
        status = .executing
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.executePlan(self.decisions, session: id)
            if self.sessionID == id { self.operationTask = nil }
        }
    }

    func cancel() { cancel(endingWith: .idle) }

    func cancelCaptureAttempt() { cancel(endingWith: .idle, cancelTask: false) }

    private func cancel(endingWith terminalStatus: Status, cancelTask: Bool = true) {
        cua?.cancelCapture()
        if cancelTask { cua?.cancelSelected() }
        guard status != .stopping else { return }
        held = false
        sessionID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        durationTask?.cancel(); durationTask = nil
        hideTask?.cancel(); hideTask = nil
        speech.cancel()
        stabilizationTask?.cancel(); interpretationTask?.cancel()
        streamSuspended = true; actionEpoch += 1
        audioLevel = 0
        isMicrophoneTest = false
        let startup = startupTask, operation = operationTask
        startup?.cancel(); operation?.cancel()
        startupTask = nil; operationTask = nil
        if startup == nil && operation == nil {
            status = terminalStatus; return
        }
        status = .stopping
        detail = completedActions > 0 ? "Stopping; actions already dispatched may have completed." : "Finishing cleanup…"
        cleanupTask = Task { [weak self] in
            await startup?.value
            await operation?.value
            guard let self else { return }
            self.cleanupTask = nil
            self.status = terminalStatus
        }
    }

    func shutdown() async { cancel(); await cua?.shutdown(); await cleanupTask?.value }

    func interruptCapture(_ reason: String) {
        guard captureActive else { return }
        cancel(endingWith: .error(reason), cancelTask: false)
        detail = reason
    }

    func startMicrophoneTest() {
        guard canBegin, !isMicrophoneTest else { return }
        let id = newSession()
        held = false; isMicrophoneTest = true; status = .starting
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionID == id { self.startupTask = nil } }
            if !Permission.microphone.isGranted { await Permission.microphone.request() }
            self.refreshPermissions()
            guard self.sessionID == id, !Task.isCancelled else { return }
            guard Permission.microphone.isGranted else { self.fail("Microphone access is needed for the input test."); return }
            do {
                let name = try await self.speech.start(session: id, inputUID: selectedUID, transcribe: false)
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.inputName = name
                self.status = .testingMicrophone
            } catch { if self.sessionID == id, !Task.isCancelled { self.fail(error.localizedDescription) } }
        }
    }

    func stopMicrophoneTest() { if isMicrophoneTest { cancel() } }

    func recordOverlayPresentation() {
        guard beganAt > 0, measurements["Overlay shown"] == nil else { return }
        measurements["Overlay shown"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000
    }

    private func newSession() -> UUID {
        deadlineTask?.cancel(); durationTask?.cancel(); hideTask?.cancel()
        let id = UUID(); sessionID = id
        automatic = config.autoExecute
        transcript = ""; decisions = []; detail = ""; resultMessage = ""; audioLevel = 0
        measurements = [:]; completedActions = 0
        stabilizationTask?.cancel(); interpretationTask?.cancel()
        stream = IncrementalCommandCoordinator(); streamRevision = 0; readyRevision = -1
        streamFinal = false; streamSuspended = false; pendingControl = nil; stabilizingCommand = nil
        liveDictationActive = false; liveDictationDeferred = false
        actionEpoch += 1; lastStreamResult = ""; lastStreamFailure = nil; reviewAfterOperation = false
        beganAt = ProcessInfo.processInfo.systemUptime
        return id
    }

    private func receive(_ event: SpeechEvent, session id: UUID) {
        guard sessionID == id else { return }
        let accepting = status == .starting || status == .listening || status == .finishing || status == .testingMicrophone
        guard accepting else { return }
        switch event {
        case .timing(let name, let milliseconds):
            guard milliseconds.isFinite, milliseconds >= 0 else { return }
            measurements[name] = milliseconds
        case .level(let level): audioLevel = level
        case .revision(let revision, let text):
            cua?.speech.record(revision)
            receive(.partial(text), session: id)
        case .partial(let text):
            guard text != transcript else { return }
            transcript = text
            if measurements["First partial"] == nil { measurements["First partial"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000 }
            if automatic {
                if let cua { cua.update(text, final: false) }
                else { updateStream(final: false) }
            }
        case .final(let text):
            transcript = text
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            if held {
                suspendStream()
                detail = "Recognition ended before you released Fn. Release the key, then review the text."
                status = .awaitingRelease
            } else {
                measurements["Transcript finalized"] = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000
                submit(text, session: id)
            }
        case .failure(let message):
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            suspendStream()
            detail = "Speech recognition stopped: \(message)"
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(detail) }
            else if held { status = .awaitingRelease }
            else { showTranscriptReview() }
        }
    }

    private func showTranscriptReview() {
        if let cua {
            cua.cancelCapture()
            if automatic {
                do { transcript = try cua.speech.reviewRemainder(transcript) }
                catch { fail(error.localizedDescription); return }
            }
            cua.begin(app: commandFrontmostApp)
            status = transcript.isEmpty ? .idle : .reviewTranscript
            return
        }
        suspendStream()
        if operationTask != nil {
            reviewAfterOperation = true
            status = .stopping
            return
        }
        if liveDictationActive {
            fail("Live dictation stopped. Text already inserted is kept; start a new hold to continue.")
            return
        }
        if stream.hasCommitted {
            do { transcript = try stream.remainder(in: transcript) }
            catch { fail(error.localizedDescription); return }
            stream = IncrementalCommandCoordinator()
        }
        audioLevel = 0
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let error = lastStreamFailure { fail("\(completedActions) action(s) completed. " + error); return }
            if completedActions > 0, let id = sessionID { complete("Earlier actions completed; no remaining speech to review.", session: id) }
            else { fail("No usable speech was captured. Hold Fn and try again.") }
        } else {
            if let error = lastStreamFailure { detail += " · " + error + ". Only remaining speech is shown." }
            status = .reviewTranscript
        }
    }

    private func submit(_ text: String, session id: UUID) {
        if let cua {
            guard sessionID == id else { return }
            transcript = text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .idle; return }
            if automatic { status = .executing; cua.update(text, final: true) }
            else { status = .awaitingConfirm; detail = "Run this request through Cua?" }
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { if completedActions > 0 { complete(lastStreamResult, session: id) } else { status = .idle }; return }
        guard sessionID == id else { return }
        transcript = text
        if automatic {
            streamSuspended = false
            updateStream(final: true)
            return
        }
        status = .thinking
        let target = commandFrontmostApp
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionID == id { self.operationTask = nil } }
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await self.interpret(text, target)
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.measurements["Interpretation"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.decisions = result
                self.latencyMs = result.map(\.latencyMs).max() ?? 0
                self.model = result.first?.model ?? ""
                self.history = Array((result + self.history).prefix(10))
                if result.allSatisfy({ $0.action == .none }) {
                    self.complete("No action taken", session: id)
                } else { self.status = .awaitingConfirm }
            } catch {
                if self.sessionID == id, !Task.isCancelled { self.fail(error.localizedDescription) }
            }
        }
    }

    private func executePlan(_ plan: [Decision], session id: UUID) async {
        status = .executing
        let actionable = plan.filter { $0.action != .none }
        var results: [String] = []
        do {
            let start = ProcessInfo.processInfo.systemUptime
            for decision in actionable {
                try Task.checkCancellation()
                guard sessionID == id else { return }
                detail = decision.displaySummary
                results.append(try await execute(decision))
                completedActions += 1
                try Task.checkCancellation()
                guard sessionID == id else { return }
            }
            measurements["Action dispatch"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            complete(results.isEmpty ? "No action taken" : results.joined(separator: " · "), session: id)
        } catch {
            if sessionID == id, !Task.isCancelled {
                fail((completedActions > 0 ? "\(completedActions) action(s) dispatched. " : "") + error.localizedDescription)
            }
        }
    }

    private func suspendStream() {
        cua?.cancelCapture()
        streamSuspended = true; actionEpoch += 1
        stabilizationTask?.cancel(); interpretationTask?.cancel()
        pendingControl = nil
    }

    private func updateStream(final: Bool) {
        guard !streamSuspended, let id = sessionID else { return }
        streamRevision += 1; streamFinal = final
        do {
            let literal = try stream.dictation(in: transcript)
            if liveDictationActive && literal == nil {
                fail("Recognition changed the dictation instruction. Text already inserted is kept; start a new hold.")
                return
            }
            if literal != nil, !liveDictationDeferred, held || final {
                stabilizationTask?.cancel(); stabilizingCommand = nil
                readyRevision = streamRevision
                eligibleAt = ProcessInfo.processInfo.systemUptime
                startStreamWorker(id)
                return
            }
        } catch { fail(error.localizedDescription); return }
        if let control = stream.control(in: transcript, installedApps: installedApps) {
            // If there is an uncommitted command before the correction, remove
            // that pending command rather than undoing an unrelated earlier one.
            let remainder = (try? stream.remainder(in: transcript)) ?? ""
            controlReversesLaunch = IncrementalCommandCoordinator.clean(remainder).hasPrefix(control.text)
            stabilizationTask?.cancel(); stabilizingCommand = nil
            stream.commit(control, transcript: transcript)
            pendingControl = control
            correctionAt = ProcessInfo.processInfo.systemUptime
            eligibleAt = correctionAt
            actionEpoch += 1
            interpretationTask?.cancel()
            readyRevision = streamRevision
            startStreamWorker(id)
            return
        }
        if final {
            stabilizationTask?.cancel(); stabilizingCommand = nil
            readyRevision = streamRevision
            eligibleAt = ProcessInfo.processInfo.systemUptime
            if !held { status = .thinking }
            startStreamWorker(id)
        } else if held {
            let candidate: IncrementalCommandCoordinator.Candidate?
            do { candidate = try stream.next(in: transcript, final: false, installedApps: installedApps) }
            catch { fail(error.localizedDescription); return }
            guard let candidate else {
                stabilizationTask?.cancel(); stabilizingCommand = nil; readyRevision = -1
                return
            }
            let key = Self.commandKey(candidate.text)
            if stabilizingCommand == key {
                // Later words do not make an already-complete earlier command
                // unstable. Only a change to that command restarts its timer.
                if readyRevision >= 0 { readyRevision = streamRevision; startStreamWorker(id) }
                return
            }
            stabilizationTask?.cancel()
            stabilizingCommand = key; readyRevision = -1
            stabilizationTask = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: UInt64(self.timings.stabilization * 1e9)) } catch { return }
                guard self.sessionID == id, self.held, !self.streamSuspended,
                      self.stabilizingCommand == key else { return }
                self.readyRevision = self.streamRevision
                self.eligibleAt = ProcessInfo.processInfo.systemUptime
                self.startStreamWorker(id)
            }
        }
    }

    private static func commandKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func startStreamWorker(_ id: UUID) {
        guard operationTask == nil, !streamSuspended else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(id)
            if self.sessionID == id {
                self.operationTask = nil
                if self.reviewAfterOperation {
                    self.reviewAfterOperation = false
                    self.showTranscriptReview()
                }
            }
        }
    }

    private func runStream(_ id: UUID) async {
        while sessionID == id, !Task.isCancelled, !streamSuspended {
            do {
                if let control = pendingControl {
                    let epoch = actionEpoch, correctionStart = correctionAt
                    pendingControl = nil
                    if control.kind != .stop, controlReversesLaunch {
                        detail = "Reversing the last launch…"
                        lastStreamResult = try await undo()
                        measurements["Correction to reversal"] = (ProcessInfo.processInfo.systemUptime - correctionStart) * 1000
                        commandFrontmostApp = frontmost()
                        guard sessionID == id, !Task.isCancelled, !streamSuspended else { return }
                    } else { lastStreamResult = "Pending actions stopped" }
                    guard epoch == actionEpoch else { continue }
                    detail = lastStreamResult
                    if control.kind == .replace {
                        let replacement = IncrementalCommandCoordinator.replacement(from: control.text)
                        let task = Task { try await self.interpret(replacement, self.commandFrontmostApp) }
                        interpretationTask = task
                        let actions: [Decision]
                        do { actions = try await task.value }
                        catch {
                            interpretationTask = nil
                            if epoch != actionEpoch || streamSuspended { continue }
                            throw error
                        }
                        interpretationTask = nil
                        guard sessionID == id, !Task.isCancelled, epoch == actionEpoch, !streamSuspended else { continue }
                        try await dispatchStream(actions, id: id, epoch: epoch)
                    }
                    continue
                }
                guard readyRevision == streamRevision else { return }
                let snapshot = transcript, revision = streamRevision, epoch = actionEpoch
                if !liveDictationDeferred, let literal = try stream.dictation(in: snapshot) {
                    let text = SlotExtractor.dictationText(from: literal.text) ?? ""
                    if !text.isEmpty || liveDictationActive {
                        let decision = Decision(clause: literal.text, action: .dictate,
                            targetApp: commandFrontmostApp, text: text, confidence: 1, model: "local-live-dictation")
                        let start = ProcessInfo.processInfo.systemUptime
                        let supported = try await updateDictation(decision)
                        liveDictationActive = liveDictationActive || supported
                        guard sessionID == id, !Task.isCancelled, !streamSuspended else { return }
                        if supported {
                            if measurements["First live text"] == nil {
                                measurements["First live text"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000
                            }
                            measurements["Live text update"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                            lastStreamResult = "Typed text in \(commandFrontmostApp ?? "the selected field")"
                            detail = held ? "Typing in \(commandFrontmostApp ?? "the selected field")…" : lastStreamResult
                            if snapshot != transcript { continue }
                            if streamFinal {
                                stream.commit(literal, transcript: snapshot)
                                completedActions += 1
                                decisions = [decision]; model = decision.model
                                history = Array(([decision] + history).prefix(10))
                                continue
                            }
                            return
                        }
                        guard !liveDictationActive else {
                            throw ExecutorError.controlFailed("Live text updates stopped. Inserted text is kept; start a new hold.")
                        }
                        liveDictationDeferred = true
                        detail = "This field uses dictation on release."
                    }
                    if !streamFinal { return }
                }
                guard let candidate = try stream.next(in: snapshot, final: streamFinal, installedApps: installedApps) else {
                    if streamFinal { complete(lastStreamResult.isEmpty ? "No action taken" : lastStreamResult, session: id) }
                    else { status = held ? .listening : .finishing }
                    return
                }
                guard candidate.kind == .command else { return }
                if candidate.text.isEmpty { stream.commit(candidate, transcript: snapshot); continue }
                measurements["Command eligible"] = (eligibleAt - beganAt) * 1000
                measurements["Queue wait"] = (ProcessInfo.processInfo.systemUptime - eligibleAt) * 1000
                detail = "Understanding…"
                let start = ProcessInfo.processInfo.systemUptime
                let target = commandFrontmostApp
                let task = Task { try await self.interpret(candidate.text, target) }
                interpretationTask = task
                let result: [Decision]
                do { result = try await task.value }
                catch {
                    interpretationTask = nil
                    if sessionID != id || streamSuspended || Task.isCancelled { return }
                    if revision != streamRevision || epoch != actionEpoch { continue }
                    throw error
                }
                interpretationTask = nil
                guard sessionID == id, !Task.isCancelled, !streamSuspended else { return }
                guard epoch == actionEpoch,
                      let latest = try stream.next(in: transcript, final: streamFinal, installedApps: installedApps),
                      Self.commandKey(latest.text) == Self.commandKey(candidate.text) else { continue }
                measurements["Interpretation"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                // Commit before the first external effect, including an uncertain
                // dispatch failure; never retry an effect because recognition repeats.
                stream.commit(latest, transcript: transcript)
                try await dispatchStream(result, id: id, epoch: epoch)
                if held, !streamFinal, !streamSuspended, pendingControl == nil {
                    stabilizingCommand = nil
                    updateStream(final: false)
                }
            } catch {
                if sessionID == id, !Task.isCancelled, streamSuspended {
                    lastStreamFailure = error.localizedDescription
                } else if sessionID == id, !Task.isCancelled {
                    fail((completedActions > 0 ? "\(completedActions) action(s) dispatched. " : "") + error.localizedDescription)
                }
                return
            }
        }
    }

    private func dispatchStream(_ plan: [Decision], id: UUID, epoch: Int) async throws {
        decisions = plan; latencyMs = plan.map(\.latencyMs).max() ?? 0
        model = plan.first?.model ?? ""
        history = Array((plan + history).prefix(10))
        for decision in plan where decision.action != .none {
            guard sessionID == id, !Task.isCancelled, !streamSuspended, epoch == actionEpoch else { return }
            status = held ? .listening : (streamFinal ? .executing : .finishing)
            detail = decision.displaySummary
            let start = ProcessInfo.processInfo.systemUptime
            measurements["Eligible to dispatch"] = max(0, start - eligibleAt) * 1000
            let message = try await execute(decision)
            guard sessionID == id, !Task.isCancelled else { return }
            completedActions += 1
            measurements["Action dispatch"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if held && measurements["First action while held"] == nil {
                measurements["First action while held"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000
            }
            if [.openApp, .switchApp, .openURL, .webSearch, .createDocument].contains(decision.action), let target = resolvedTarget() ?? decision.targetApp {
                commandFrontmostApp = target
            }
            lastStreamResult = message
            if !streamSuspended { detail = message }
        }
    }

    private func complete(_ message: String, session id: UUID) {
        resultMessage = message
        status = .done
        hideTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.timings.dismissal * 1e9)) } catch { return }
            if self.sessionID == id, self.status == .done { self.status = .idle }
        }
    }

    private func cuaChanged() {
        objectWillChange.send()
        guard let cua, !isMicrophoneTest else { return }
        if let error = cua.speech.error {
            cua.cancelSelected()
            detail = error
            speech.cancel(); audioLevel = 0
            status = held ? .awaitingRelease : .error(error)
            return
        }
        detail = held && !cua.speech.message.isEmpty ? cua.speech.message : cua.message
        guard !held, [.thinking, .executing].contains(status) else { return }
        if cua.active { status = .executing }
        else if let last = cuaTasks.last, last.status == "Failed" { status = .error(last.message) }
        else if let id = sessionID { complete(cua.message.isEmpty ? "No action taken" : cua.message, session: id) }
    }

    private func fail(_ message: String) {
        cua?.cancelCapture()
        speech.cancel(); stabilizationTask?.cancel(); interpretationTask?.cancel()
        streamSuspended = true; actionEpoch += 1
        audioLevel = 0; held = false; isMicrophoneTest = false
        deadlineTask?.cancel(); durationTask?.cancel()
        status = .error(message)
    }

    private func scheduleDuration(_ id: UUID) {
        durationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.timings.warning * 1e9))
                guard self.sessionID == id, self.status == .listening else { return }
                self.detail = "Recording limit approaching — release Fn to finish."
                try await Task.sleep(nanoseconds: UInt64(max(0, self.timings.limit - self.timings.warning) * 1e9))
                guard self.sessionID == id, self.status == .listening else { return }
                self.suspendStream()
                self.speech.cancel(); self.audioLevel = 0
                self.detail = "Recording reached its limit. Release Fn, then review the captured text."
                self.status = .awaitingRelease
            } catch { }
        }
    }


}

extension Decision {
    var displaySummary: String {
        switch action {
        case .openApp: return "Open \(targetApp ?? "app")"
        case .closeApp: return "Quit \(targetApp ?? "app")"
        case .switchApp: return "Switch to \(targetApp ?? "app")"
        case .minimizeApp: return "Minimize \(targetApp ?? "app")"
        case .hideApp: return "Hide \(targetApp ?? "app")"
        case .openURL: return "Open \(url ?? "website")" + (targetApp.map { " in \($0)" } ?? "")
        case .webSearch: return "Search \(searchSite?.rawValue ?? "the web") for \(query ?? "")" + (targetApp.map { " in \($0)" } ?? "")
        case .dictate: return "Type “\(text ?? "")”" + (targetApp.map { " in \($0)" } ?? "")
        case .system: return (systemAction?.description ?? "System action") + (percent.map { " (\($0)%)" } ?? "")
        case .createDocument: return "Create document in \(targetApp ?? "TextEdit")"
        case .scrollDown: return "Scroll down"
        case .scrollUp: return "Scroll up"
        case .browserBack: return "Go back"
        case .none: return "No action"
        }
    }
}

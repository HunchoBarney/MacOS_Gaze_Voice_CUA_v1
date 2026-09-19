import AppKit
import Combine
import JevVoiceCore

struct VoiceTimings {
    var finalization: TimeInterval = 2
    var warning: TimeInterval = 50
    var limit: TimeInterval = 55
    var dismissal: TimeInterval = 1.5
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
    private let speech: SpeechCapturing
    private let authorize: () async -> Bool
    private let interpret: (String, String?) async throws -> [Decision]
    private let execute: (Decision) async throws -> String
    private let timings: VoiceTimings
    private let frontmost: () -> String?
    private var appObserver: AnyCancellable?
    private var lastExternalApp: String?
    private var commandFrontmostApp: String?
    private var sessionID: UUID?
    private var held = false
    private var startupTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var beganAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    private var completedActions = 0

    var isListening: Bool { status == .listening }
    var canBegin: Bool {
        if isMicrophoneTest && status != .stopping { return true }
        switch status { case .idle, .done, .error: return cleanupTask == nil; default: return false }
    }
    var operationActive: Bool {
        switch status { case .idle, .done, .error: return false; default: return true }
    }
    var captureActive: Bool { status == .starting || status == .listening || status == .awaitingRelease || status == .testingMicrophone }

    init(config: Config? = nil, speech: SpeechCapturing? = nil,
         authorize: (() async -> Bool)? = nil,
         interpret: ((String, String?) async throws -> [Decision])? = nil,
         execute: ((Decision) async throws -> String)? = nil,
         timings: VoiceTimings = VoiceTimings(), frontmost: (() -> String?)? = nil) {
        let config = config ?? Config.shared
        self.config = config
        self.speech = speech ?? SpeechRecognizer()
        self.authorize = authorize ?? { await SpeechRecognizer.requestAuthorization() }
        self.execute = execute ?? { try await Executor.execute($0) }
        self.timings = timings
        self.frontmost = frontmost ?? { NSWorkspace.shared.frontmostApplication?.localizedName }
        var cachedApps: [String] = []
        self.interpret = interpret ?? { text, app in
            if cachedApps.isEmpty { cachedApps = InstalledApps.all() }
            let interpreter = CommandInterpreter(client: JevClient(apiKey: config.apiKey), installedApps: cachedApps)
            return try await interpreter.interpret(transcript: text, frontmostApp: app)
        }
        lastExternalApp = self.frontmost()
        appObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastExternalApp = $0.localizedName }
        self.speech.onEvent = { [weak self] id, event in self?.receive(event, session: id) }
    }

    func refreshPermissions() { missingPermissions = Permission.missing }

    func showSetup(_ message: String) {
        guard !operationActive else { return }
        fail(message)
    }
    func begin() {
        guard canBegin else { return }
        let priorStart = startupTask
        priorStart?.cancel()
        speech.cancel()
        isMicrophoneTest = false
        held = true
        let id = newSession()
        commandFrontmostApp = lastExternalApp
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            commandFrontmostApp = frontmost() ?? lastExternalApp
        }
        status = .starting
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            await priorStart?.value
            guard let self, self.sessionID == id, !Task.isCancelled else { return }
            defer { if self.sessionID == id { self.startupTask = nil } }
            let granted = await self.authorize()
            self.refreshPermissions()
            guard self.sessionID == id, self.held, !Task.isCancelled else { return }
            guard granted else { self.fail("Microphone and Speech Recognition access are needed. Open Voice settings."); return }
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
        guard status == .reviewTranscript, let id = sessionID else { return }
        submit(transcript, session: id)
    }

    func confirm() {
        guard status == .awaitingConfirm, let id = sessionID, operationTask == nil else { return }
        status = .executing
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.executePlan(self.decisions, session: id)
            if self.sessionID == id { self.operationTask = nil }
        }
    }

    func cancel() { cancel(endingWith: .idle) }

    private func cancel(endingWith terminalStatus: Status) {
        guard status != .stopping else { return }
        held = false
        sessionID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        durationTask?.cancel(); durationTask = nil
        hideTask?.cancel(); hideTask = nil
        speech.cancel()
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

    func shutdown() async { cancel(); await cleanupTask?.value }

    func interruptCapture(_ reason: String) {
        guard captureActive else { return }
        cancel(endingWith: .error(reason))
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
        transcript = ""; decisions = []; detail = ""; resultMessage = ""; audioLevel = 0
        measurements = [:]; completedActions = 0
        beganAt = ProcessInfo.processInfo.systemUptime
        return id
    }

    private func receive(_ event: SpeechEvent, session id: UUID) {
        guard sessionID == id else { return }
        let accepting = status == .starting || status == .listening || status == .finishing || status == .testingMicrophone
        guard accepting else { return }
        switch event {
        case .level(let level): audioLevel = level
        case .partial(let text): transcript = text
        case .final(let text):
            transcript = text
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            if held {
                detail = "Recognition ended before you released Fn. Release the key, then review the text."
                status = .awaitingRelease
            } else {
                measurements["Transcript finalized"] = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000
                submit(text, session: id)
            }
        case .failure(let message):
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            detail = "Speech recognition stopped: \(message)"
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(detail) }
            else if held { status = .awaitingRelease }
            else { showTranscriptReview() }
        }
    }

    private func showTranscriptReview() {
        audioLevel = 0
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("No usable speech was captured. Hold Fn and try again.")
        } else { status = .reviewTranscript }
    }

    private func submit(_ text: String, session id: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status = .idle; return }
        guard sessionID == id else { return }
        status = .thinking
        transcript = text
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
                } else if self.config.autoExecute {
                    await self.executePlan(result, session: id)
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

    private func complete(_ message: String, session id: UUID) {
        resultMessage = message
        status = .done
        hideTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.timings.dismissal * 1e9)) } catch { return }
            if self.sessionID == id, self.status == .done { self.status = .idle }
        }
    }

    private func fail(_ message: String) {
        speech.cancel(); audioLevel = 0; held = false; isMicrophoneTest = false
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
        case .none: return "No action"
        }
    }
}

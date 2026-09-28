import AppKit
import Combine
import OSLog
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
    enum CaptureState { case idle, starting, listening, finishing, awaitingRelease, testingMicrophone, stopping }
    @Published private(set) var captureState: CaptureState = .idle
    @Published private var presentation: Status = .idle
    // Task progress lives in CuaVoiceRuntime. It never replaces an active capture's state.
    private(set) var status: Status {
        get {
            switch captureState {
            case .idle: return presentation
            case .starting: return .starting
            case .listening: return .listening
            case .finishing: return .finishing
            case .awaitingRelease: return .awaitingRelease
            case .testingMicrophone: return .testingMicrophone
            case .stopping: return .stopping
            }
        }
        set {
            switch newValue {
            case .starting: captureState = .starting
            case .listening: captureState = .listening
            case .finishing: captureState = .finishing
            case .awaitingRelease: captureState = .awaitingRelease
            case .testingMicrophone: captureState = .testingMicrophone
            case .stopping: captureState = .stopping
            default: presentation = newValue; captureState = .idle
            }
        }
    }
    @Published private(set) var transcript = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var inputName = ""
    @Published private(set) var detail = ""
    @Published private(set) var resultMessage = ""
    @Published private(set) var measurements: [String: Double] = [:]
    @Published private(set) var isMicrophoneTest = false
    @Published private(set) var microphoneReady = false
    @Published private(set) var microphoneReadiness = "Preparing microphone…"
    @Published var missingPermissions: [Permission] = Permission.missing

    private static let voiceLog = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "capture")
    /// Content-free diagnostics let physical trials be correlated without retaining
    /// raw microphone audio, spoken text, app contents, or credentials.
    private func trace(_ event: String) {
        let id = sessionID?.uuidString ?? "none"
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - beganAt) * 1000
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        Self.voiceLog.notice("capture=\(id, privacy: .public) event=\(event, privacy: .public) held=\(self.held) words=\(words) elapsed_ms=\(elapsed) status=\(self.status.title, privacy: .public)")
    }

    let config: Config
    let cua: CuaVoiceRuntime
    var cuaTasks: [CuaVoiceRuntime.Work] { cua.tasks }
    var diagnosticTask: CuaVoiceRuntime.Work? { cuaTasks.first { $0.id == cua.selectedID } }
    func stopAll() { cancel(); cua.stopAll() }
    func selectTask(_ id: UUID) { cua.select(id) }
    func cancelTask(_ id: UUID) { cua.cancel(id) }
    func approveTask(_ id: UUID, approved: Bool) { cua.resolveApproval(id, approved: approved) }
    var pendingTaskApproval: CuaVoiceRuntime.Work? { cuaTasks.first(where: { $0.approval != nil }) }
    private let speech: SpeechCapturing
    private let authorize: () async -> Bool
    private let timings: VoiceTimings
    private let frontmost: () -> String?
    private var appObserver: AnyCancellable?
    private var lastExternalApp: String?
    private var commandFrontmostApp: String?
    private var sessionID: UUID?
    private var held = false
    private var automatic = true
    private var microphoneTask: Task<Void, Never>?
    private var microphoneEnabled = true
    private var configuredDevice: MicrophoneDevice?
    private var startupTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var beganAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    var isListening: Bool { status == .listening }
    var canBegin: Bool {
        guard microphoneEnabled else { return false }
        if !held, !cua.speech.busy, cleanupTask == nil, startupTask == nil,
           [.executing, .thinking].contains(status) { return true }
        if isMicrophoneTest && status != .stopping { return true }
        switch status { case .idle, .done, .error: return cleanupTask == nil; default: return false }
    }
    var operationActive: Bool {
        if cua.active { return true }
        switch status { case .idle, .done, .error: return false; default: return true }
    }
    var captureActive: Bool { status == .starting || status == .listening || status == .finishing || status == .awaitingRelease || status == .testingMicrophone }

    init(config: Config? = nil, speech: SpeechCapturing? = nil,
         authorize: (() async -> Bool)? = nil,
         timings: VoiceTimings = VoiceTimings(), frontmost: (() -> String?)? = nil,
         cuaRuntime: CuaVoiceRuntime? = nil) {
        let config = config ?? Config.shared
        self.config = config
        self.speech = speech ?? SpeechAnalyzerCapture()
        self.authorize = authorize ?? { await SpeechAnalyzerCapture.requestAuthorization() }
        self.cua = cuaRuntime ?? CuaVoiceRuntime(config: config)
        self.timings = timings
        self.frontmost = frontmost ?? { NSWorkspace.shared.frontmostApplication?.localizedName }
        lastExternalApp = self.frontmost()
        appObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastExternalApp = $0.localizedName }
        self.cua.onChange = { [weak self] in self?.cuaChanged() }
        self.speech.onReadiness = { [weak self] readiness in
            guard let self else { return }
            switch readiness {
            case .preparing: self.microphoneReady = false; self.microphoneReadiness = "Preparing microphone…"
            case .ready(let name): self.microphoneReady = true; self.microphoneReadiness = "Ready — " + name
            case .unavailable(let reason): self.microphoneReady = false; self.microphoneReadiness = reason
            case .interrupted(let reason):
                self.microphoneReady = false; self.microphoneReadiness = reason
                if self.microphoneEnabled { self.prepareMicrophone() }
            }
        }
        self.speech.onEvent = { [weak self] id, event in self?.receive(event, session: id) }
    }

    func refreshPermissions() {
        missingPermissions = Permission.missing
        if !Permission.microphone.isGranted, microphoneReady { suspendMicrophone("Microphone permission was removed.") }
    }

    func prepareMicrophone(deviceChanged: Bool = false) {
        let device = try? MicrophoneCatalog.resolve(uid: config.microphoneUID)
        let changed = deviceChanged && device != configuredDevice
        if deviceChanged && !changed { return }
        if changed, captureActive { interruptCapture("The selected microphone changed. Hold Fn again.") }
        configuredDevice = device
        microphoneEnabled = true
        let prior = microphoneTask
        let uid = config.microphoneUID
        microphoneTask = Task { [weak self] in
            await prior?.value
            guard let self, self.microphoneEnabled, !Task.isCancelled else { return }
            if changed { await self.speech.suspend() }
            guard self.microphoneEnabled, !Task.isCancelled else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await self.speech.prepare(inputUID: uid)
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                Self.voiceLog.notice("microphone_preparation_ms=\(milliseconds)")
            }
            catch { self.microphoneReady = false; self.microphoneReadiness = error.localizedDescription }
        }
    }

    func suspendMicrophone(_ reason: String) {
        microphoneEnabled = false
        microphoneReady = false; microphoneReadiness = reason
        if captureActive { interruptCapture(reason) }
        speech.cancel()
        let prior = microphoneTask
        prior?.cancel()
        microphoneTask = Task { [weak self] in
            await self?.speech.suspend()
            await prior?.value
        }
    }

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
        cua.begin(app: commandFrontmostApp, captureID: id)
        status = .starting
        trace("fn_down")
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            await priorStart?.value
            await self?.microphoneTask?.value
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
                self.trace("capture_started")
                self.measurements["Microphone ready"] = (ProcessInfo.processInfo.systemUptime - self.beganAt) * 1000
                if self.status == .starting { self.status = .listening }
                self.scheduleDuration(id)
            } catch {
                if self.sessionID == id, !Task.isCancelled { self.fail(error.localizedDescription) }
            }
        }
    }

    func finish() {
        trace("fn_up")
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
                self.trace("capture_finalization_timeout")
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
        guard status == .awaitingConfirm else { return }
        status = .executing
        cua.update(transcript, final: true)
    }

    func cancel() { cancel(endingWith: .idle) }

    func cancelCaptureAttempt() { cancel(endingWith: .idle, cancelTask: false) }

    private func cancel(endingWith terminalStatus: Status, cancelTask: Bool = true) {
        cua.cancelCapture()
        if cancelTask { cua.cancelSelected() }
        guard status != .stopping else { return }
        held = false
        trace("capture_cancelled")
        sessionID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        durationTask?.cancel(); durationTask = nil
        hideTask?.cancel(); hideTask = nil
        speech.cancel()
        audioLevel = 0
        isMicrophoneTest = false
        let startup = startupTask
        startup?.cancel()
        startupTask = nil
        if startup == nil { status = terminalStatus; return }
        status = .stopping
        detail = "Finishing cleanup…"
        cleanupTask = Task { [weak self] in
            await startup?.value
            guard let self else { return }
            self.cleanupTask = nil
            self.status = terminalStatus
        }
    }

    func shutdown() async {
        microphoneEnabled = false
        let microphone = microphoneTask
        microphone?.cancel()
        cancel()
        await speech.suspend()
        await microphone?.value
        await cua.shutdown()
        await cleanupTask?.value
    }

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
        transcript = ""; detail = ""; resultMessage = ""; audioLevel = 0
        measurements = [:]
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
            Self.voiceLog.notice("capture=\(id.uuidString, privacy: .public) timing=\(name, privacy: .public) milliseconds=\(milliseconds)")
        case .level(let level): audioLevel = level
        case .transcript(let snapshot):
            cua.speech.record(snapshot)
            let text = snapshot.text
            // Finality can change without changing any characters.
            transcript = text
            trace(snapshot.segments.last?.isFinal == true ? "recognition_final_segment" : "recognition_volatile_segment")
            if measurements["First partial"] == nil { measurements["First partial"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000 }
            if automatic {
                cua.update(text, final: false)
            }
        case .partial(let text):
            guard text != transcript else { return }
            transcript = text
            if measurements["First partial"] == nil { measurements["First partial"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000 }
            if automatic {
                cua.update(text, final: false)
            }
        case .final(let text):
            transcript = text
            trace("capture_final")
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            if held {
                cua.cancelCapture()
                detail = "Recognition ended before you released Fn. Release the key, then review the text."
                status = .awaitingRelease
            } else {
                measurements["Transcript finalized"] = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000
                submit(text, session: id)
            }
        case .failure(let message):
            trace("capture_failed")
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            cua.cancelCapture()
            detail = "Speech recognition stopped: \(message)"
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(detail) }
            else if held { status = .awaitingRelease }
            else { showTranscriptReview() }
        }
    }

    private func showTranscriptReview() {
        cua.cancelCapture()
        if automatic {
            do { transcript = try cua.speech.reviewRemainder(transcript) }
            catch { fail(error.localizedDescription); return }
        }
        cua.begin(app: commandFrontmostApp, captureID: sessionID ?? UUID())
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("No usable speech remains. Hold Fn and try again.")
        } else { status = .reviewTranscript }
    }

    private func submit(_ text: String, session id: UUID) {
        guard sessionID == id else { return }
        transcript = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelCaptureAttempt()
            return
        }
        if automatic { status = .executing; cua.update(text, final: true) }
        else { status = .awaitingConfirm; detail = "Run this request through Cua?" }
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
        guard !isMicrophoneTest else { return }
        trace("voice_state_" + cua.speech.outcome)
        if let error = cua.speech.error {
            detail = error
            speech.cancel(); audioLevel = 0
            status = held ? .awaitingRelease : .error(error)
            return
        }
        detail = held && !cua.speech.message.isEmpty ? cua.speech.message : cua.message
        guard !held, [.thinking, .executing].contains(status) else { return }
        if cua.active { status = .executing }
        else if cua.speech.outcome == "clarification" { status = .error(cua.message) }
        else if let last = cuaTasks.last, last.status == "Failed" { status = .error(last.message) }
        else if let id = sessionID { complete(cua.message.isEmpty ? "No action taken" : cua.message, session: id) }
    }

    private func fail(_ message: String) {
        trace("capture_failed")
        cua.cancelCapture()
        speech.cancel()
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
                self.trace("capture_limit")
                self.cua.cancelCapture()
                self.speech.cancel(); self.audioLevel = 0
                self.detail = "Recording reached its limit. Release Fn, then review the captured text."
                self.status = .awaitingRelease
            } catch { }
        }
    }


}

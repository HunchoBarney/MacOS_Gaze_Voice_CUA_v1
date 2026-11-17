import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import JevVoiceCore

/// P3 G5 physical slice: real Fn holds + real microphone + the production
/// `LocalSpeechSession` admission path + the production `VoiceTaskCoordinator`
/// dispatch path (CuaDriver `launch_app`) + independent frontmost-PID
/// verification. Emits `.agent/results/P3/live.json` — the schema
/// `verify-p3.py live` consumes. The physical mode never simulates input;
/// the separate --self-test scripts holds from recorded audio and cannot
/// write live.json. Every row carries turn and effect evidence. Product-level
/// wrong actions abort the run without writing live.json; every attempt —
/// passing or not — is appended to live-attempts.jsonl.
@MainActor
enum VoiceLiveTrial {
    nonisolated static func main() -> Never {
        Task { @MainActor in
            do { exit(try await run()) }
            catch {
                FileHandle.standardError.write(Data("P3 live failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        // dispatchMain() drains the main queue but does not pump
        // CFRunLoopGetMain() sources — the Fn monitor's mach-port source
        // would never fire (verified: listen-only probe on CFRunLoopRunInMode
        // received key-63 while this driver saw nothing). RunLoop.run()
        // services the real runloop and still drains the main queue.
        RunLoop.main.run()
        fatalError("main runloop exited with the event tap still installed")
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var results: URL { root.appendingPathComponent(".agent/results/P3") }
    private static let calculator = "com.apple.calculator"
    private static let textEdit = "com.apple.TextEdit"

    struct Spec {
        enum Kind { case clearOpen, negated, cancelDuringFinish, dictation, confusable }
        let id: String, kind: Kind, utterance: String, instruction: String
    }

    static func completionFailureMessage(foregroundObserved: Bool, taskMessage: String) -> String {
        if foregroundObserved {
            return "Calculator was seen in front, but task-window verification failed: \(taskMessage)"
        }
        return "Driver did not complete successfully: \(taskMessage)"
    }

    private static let clearSpecs: [Spec] = [
        .init(id: "live-c1", kind: .clearOpen, utterance: "open Calculator",
              instruction: "Hold Fn, say “open Calculator”, release."),
        .init(id: "live-c2", kind: .clearOpen, utterance: "show Calculator",
              instruction: "Hold Fn, say “show Calculator”, release."),
        .init(id: "live-c3", kind: .clearOpen, utterance: "bring Calculator to front",
              instruction: "Hold Fn, say “bring Calculator to front”, release."),
        .init(id: "live-c4", kind: .clearOpen, utterance: "switch to Calculator",
              instruction: "Hold Fn, say “switch to Calculator”, release.")
    ]
    private static let controlSpecs: [Spec] = [
        .init(id: "live-n1", kind: .negated, utterance: "don't open Calculator",
              instruction: "Hold Fn, say “don't open Calculator”, release. Calculator must NOT open."),
        .init(id: "live-n2", kind: .cancelDuringFinish, utterance: "open Calculator",
              instruction: "Hold Fn, say “open Calculator”, press Esc while still holding Fn, then release. Nothing may run."),
        .init(id: "live-n3", kind: .dictation, utterance: "open Calculator",
              instruction: "Hold Fn+Ctrl together, say “open Calculator”, release. The words must be typed into TextEdit — Calculator must NOT open."),
        .init(id: "live-n4", kind: .confusable, utterance: "open GateHub",
              instruction: "Hold Fn, say “open GateHub”, release. It must clarify, not open anything.")
    ]

    @MainActor
    final class Lane {
        let session: LocalSpeechSession
        let monitor: FnInputMonitor
        let microphone: MicrophoneInput
        let hardwareFormat: AVAudioFormat
        let pcm: AVAudioFormat
        var turn: VoiceTurnToken?
        var lastToken: VoiceTurnToken?
        var feed: ConvertedAudioFeed?
        var consumer: Task<Void, Never>?
        var armed = false
        var fnUp: TimeInterval = 0
        var pressAt: TimeInterval = 0
        var dispatchMark: TimeInterval?
        var dispatchCount = 0
        var admission: VoiceAdmission?
        var failure: String?
        private(set) var inputFailure: String?
        var dispatchResult: String?
        var latencySpans: [JSONValue] = []
        private(set) var preparing = false
        private var attemptID = UUID()
        private var resolved = true
        private var waiter: CheckedContinuation<Void, Never>?

        init(session: LocalSpeechSession, monitor: FnInputMonitor,
             microphone: MicrophoneInput, hardwareFormat: AVAudioFormat, pcm: AVAudioFormat) {
            self.session = session; self.monitor = monitor
            self.microphone = microphone; self.hardwareFormat = hardwareFormat; self.pcm = pcm
        }

        var capturing: Bool { preparing || turn != nil }

        func arm() {
            guard inputFailure == nil else {
                failure = inputFailure
                resolve()
                return
            }
            attemptID = UUID()
            turn = nil; lastToken = nil; feed = nil; consumer = nil
            fnUp = 0; pressAt = 0
            dispatchMark = nil; dispatchCount = 0; admission = nil; failure = nil
            dispatchResult = nil; preparing = false
            latencySpans = []
            waiter?.resume(); waiter = nil
            resolved = false
            armed = true
        }
        func disarm() { armed = false }

        /// A case blocks here until a hold resolves (finish/cancel/failure).
        func waitOutcome(timeout: TimeInterval = 90) async {
            guard !resolved else { return }
            let owner = attemptID
            let watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                catch { return }
                guard let self, self.attemptID == owner, !self.resolved else { return }
                await self.abort("No completed Fn hold within \(Int(timeout)) seconds.")
            }
            defer { watchdog.cancel() }
            await withCheckedContinuation { waiter = $0 }
        }
        func resolve() { resolved = true; armed = false; waiter?.resume(); waiter = nil }

        func handle(_ action: FnInputState.Action) async {
            switch action {
            case .begin: await begin(mode: .command)
            case .finish: await finish()
            case .cancel, .cancelCapture: await cancel()
            case .none: break
            }
        }

        func begin(mode: VoiceCaptureMode) async {
            guard armed, !capturing else { return }
            preparing = true
            let owner = attemptID
            let now = ProcessInfo.processInfo.systemUptime
            pressAt = now
            do {
                let token = try await session.beginCapture(id: UUID(), mode: mode, now: now)
                guard attemptID == owner, armed else {
                    await session.cancelCapture(token)
                    return
                }
                let feed = try ConvertedAudioFeed(input: hardwareFormat, output: pcm)
                self.turn = token; lastToken = token; self.feed = feed
                preparing = false
                consumer = Task { [weak self] in
                    var sequence = 0
                    do {
                        for try await buffer in feed.stream {
                            guard let self, self.turn == token else { return }
                            try await self.session.consume(VoicePCMFrame(copying: buffer),
                                                           sequence: sequence, turn: token)
                            sequence += 1
                        }
                    } catch {
                        guard let self, self.attemptID == owner, self.armed else { return }
                        await self.abort("Audio capture failed: \(error.localizedDescription)")
                    }
                }
                microphone.gate.open(feed, at: AVAudioTime.hostTime(forSeconds: now))
                say("    Listening — keep Fn held while speaking.")
            } catch {
                guard attemptID == owner else { return }
                preparing = false
                failure = "\(type(of: error)): \(error.localizedDescription)"
                resolve()
            }
        }

        private func finish() async {
            guard preparing || turn != nil else { return }
            if fnUp == 0 { fnUp = ProcessInfo.processInfo.systemUptime }
            if preparing {
                // No feed existed at the real release boundary. Discard the
                // pre-roll and reject, rather than capturing post-release
                // speech or moving the release/deadline to a later time.
                microphone.gate.close()?.finish()
                await abort("Fn released before capture was ready. No command submitted.")
                return
            }
            guard let token = turn, let feed else { return }
            let owner = attemptID
            let released = fnUp
            microphone.gate.close()?.finish()
            say("    Fn released — recognizing \(String(format: "%.1f", feed.audioDurations().converted))s of audio…")
            let consumer = self.consumer
            do {
                let result = try await session.finishCapture(
                    token, acceptedFrames: feed.emittedFrameCount(), releasedAt: released,
                    capturedSeconds: feed.audioDurations().converted,
                    drain: { await consumer?.value })
                guard attemptID == owner, !resolved else { return }
                admission = result
                if let result { say("    Heard: “\(result.text)” → \(result.route.rawValue)") }
            } catch {
                guard attemptID == owner, !resolved else { return }
                failure = "\(type(of: error)): \(error.localizedDescription)"
            }
            turn = nil; self.feed = nil; self.consumer = nil
            resolve()
        }

        private func cancel() async {
            await abort(nil)
            say("    Cancelled — no command submitted.")
        }

        /// Timeout/abort seam: ends any in-flight capture so a stranded hold
        /// can't leak state into the next case, then releases the waiter.
        func abort(_ reason: String?) async {
            let owner = attemptID
            armed = false
            preparing = false
            failure = failure ?? reason
            microphone.gate.close()?.finish()
            consumer?.cancel()
            if let token = turn {
                await session.cancelCapture(token)
            }
            guard attemptID == owner else { return }
            turn = nil; feed = nil; consumer = nil
            resolve()
        }

        func interrupt(_ message: String) {
            inputFailure = "input_interruption: \(message)"
            armed = false
            failure = "input_interruption: \(message)"
            microphone.gate.close()?.finish()
            consumer?.cancel()
            preparing = false
            let token = turn; turn = nil; feed = nil; consumer = nil
            if let token { Task { await session.cancelCapture(token) } }
            resolve()
        }
    }

    private static func run() async throws -> Int32 {
        let argv = CommandLine.arguments
        if argv.contains("--microphone-preflight") {
            return try await microphonePreflight()
        }
        let automated = argv.contains("--self-test")
        guard automated || isatty(STDIN_FILENO) == 1 else {
            throw VoiceError("The physical trial needs an interactive terminal.")
        }
        func option(_ name: String) -> String? {
            argv.firstIndex(of: name).flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
        }
        let evidenceName = automated ? "self-test.json" : "live.json"
        let source = automated ? "automated-recording-and-scripted-hold" : "physical"
        let output = URL(fileURLWithPath: option("--out") ?? results.appendingPathComponent(evidenceName).path)
            .standardizedFileURL
        guard output == results.appendingPathComponent(evidenceName).standardizedFileURL else {
            throw VoiceError("Output must be the phase-owned \(evidenceName).")
        }
        guard !argv.contains("--remote-live") else {
            throw VoiceError("This harness tests local voice only. --remote-live does not implement server validation.")
        }
        let only = option("--only")
        let runID = UUID().uuidString
        let attemptsURL = results.appendingPathComponent(automated ? "self-test-attempts.jsonl" : "live-attempts.jsonl")
        let executable = URL(fileURLWithPath: argv[0]).standardizedFileURL
        let executedArtifact = try digest(executable)
        let initialApp = NSWorkspace.shared.frontmostApplication
        let baselineApp = automated || initialApp?.bundleIdentifier == calculator
            ? textEdit : (initialApp?.bundleIdentifier ?? textEdit)

        // Artifact binding: the trial runs on the exact binary the build record
        // binds — a stale binary can never mint live.json.
        let build = try loadJSON(results.appendingPathComponent("build.json"))
        guard let artifact = build["artifact_sha256"]?.string else {
            throw VoiceError("Missing source artifact binding in build.json.")
        }
        guard let sources = build["source_hashes"]?.object else {
            throw VoiceError("Missing source manifest in build.json.")
        }
        for (path, expected) in sources {
            guard try digest(root.appendingPathComponent(path)) == expected.string else {
                throw VoiceError("Source changed since this build; rebuild before spending time on the trial.")
            }
        }
        var installReceiptSHA: String?
        if !automated || executedArtifact != artifact {
            let receiptURL = results.appendingPathComponent("install.json")
            let installed = try loadJSON(receiptURL)
            guard installed["source_artifact_sha256"]?.string == artifact,
                  installed["installed_artifact_sha256"]?.string == executedArtifact,
                  installed["codesign_verified"]?.bool == true,
                  installed["review_receipt_sha256"]?.string == (try digest(results.appendingPathComponent("review.json"))),
                  let bundle = installed["bundle"]?.string,
                  executable == URL(fileURLWithPath: bundle).appendingPathComponent("Contents/MacOS/JevVoice").standardizedFileURL else {
                throw VoiceError("Use the reviewed installed binary; the installation receipt is missing or stale.")
            }
            installReceiptSHA = try digest(receiptURL)
            say("Checking current review, source, signed installation and build identity…")
            let preflight = Process()
            preflight.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            preflight.arguments = [root.appendingPathComponent("scripts/verify-p3.py").path, "installation"]
            preflight.standardOutput = FileHandle.standardOutput
            preflight.standardError = FileHandle.standardError
            try preflight.run()
            preflight.waitUntilExit()
            guard preflight.terminationStatus == 0 else {
                throw VoiceError("Installed-build preflight failed; no holds requested. Rebuild/review/install first.")
            }
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.chriswozniczek.jevvoice")
            .allSatisfy({ $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }) else {
            throw VoiceError("Quit the Jev Voice app before this trial so only one Fn listener is active.")
        }

        say(automated
            ? "P3 automated desktop check — recorded speech + scripted holds; real ASR, dispatch and app effects. Not Fn/microphone proof."
            : "P3 physical trial — real Fn and microphone. Ctrl+C aborts. This terminal trial has no pill.")
        say("Calculator will NOT be opened by setup. Leave its windows alone; the test hides it between verified cases.")
        say("Wait for READY, hold Fn while speaking, then release. TextEdit is needed only for the dictation field.")
        if !automated {
            say("Formal run: 1 cold turn + 2 warmups + 24 scored holds. A scored failure stops the run; it cannot be retried into a pass.")
        }
        // Accessibility gates both the Fn tap and the AX readback.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            say("Grant Accessibility to this process, then wait (checking for 60s)…")
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while !AXIsProcessTrusted(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard AXIsProcessTrusted() else { throw VoiceError("Accessibility permission is required for the physical Fn path.") }
        }

        let monitor = FnInputMonitor()
        defer { monitor.stop() }
        monitor.dictationChordEnabled = true
        let session = LocalSpeechSession(provider: LocalTranscriber.shared) { _ in }
        let microphone = MicrophoneInput()
        let hardwareFormat: AVAudioFormat
        if automated {
            hardwareFormat = try AVAudioFile(forReading: recording("h15")).processingFormat
        } else {
            guard Permission.microphone.isGranted else {
                throw VoiceError("Microphone access is required before this trial can request any holds.")
            }
            say("Preparing microphone…")
            let hardware = try await microphone.prepare(device: MicrophoneCatalog.resolve(uid: nil),
                interrupted: { Task { @MainActor in monitor.onInterruption("Microphone interrupted.") } })
            hardwareFormat = hardware.format
            say("Microphone ready: \(hardware.name)")
        }
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                      channels: 1, interleaved: true) else {
            throw VoiceError("Could not build the speech audio format.")
        }
        let lane = Lane(session: session, monitor: monitor, microphone: microphone,
                        hardwareFormat: hardwareFormat, pcm: pcm)
        say("Wiring dispatch coordinator…")
        // The trial never needs a hosted key — in-memory stores keep an
        // unsigned CLI binary out of Keychain prompts entirely. A silent gaze
        // stream and no codex probe keep the coordinator headless-clean.
        struct MemoryKeys: APIKeyStore {
            func read() throws -> String? { nil }
            func save(_ apiKey: String) throws {}
            func delete() throws {}
        }
        let config = Config(defaults: .standard, keyStore: MemoryKeys(),
                            openAIKeyStore: MemoryKeys(),
                            environment: ProcessInfo.processInfo.environment,
                            codexAuth: CodexAuth(binary: nil))
        let cua = VoiceTaskCoordinator(config: config, jevAPIKey: { config.apiKey },
                                       gazeService: GazeService(
                                        stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
                                       overlay: TargetOverlay())
        defer { cua.stopAll() }
        cua.onLatencySpan = { [weak lane] stage, start, end in
            lane?.latencySpans.append(.object([
                "stage": .string(stage), "start": .number(start), "end": .number(end),
                "milliseconds": .number((end - start) * 1000)
            ]))
        }

        session.execute = { [weak lane] admission in
            guard let lane else { return }
            lane.dispatchMark = lane.dispatchMark ?? ProcessInfo.processInfo.systemUptime
            lane.dispatchCount += 1
            switch admission.intent {
            case "respond":
                guard let taskID = admission.slots["task_id"].flatMap(UUID.init(uuidString:)),
                      let askID = admission.slots["ask_id"].flatMap(UUID.init(uuidString:)) else { return }
                _ = await cua.respondToTaskExact(admission.text, taskID: taskID, askID: askID,
                                                 captureID: admission.turn.id)
            case "cancel":
                guard let taskID = admission.slots["task_id"].flatMap(UUID.init(uuidString:)) else { return }
                cua.cancel(taskID)
            default:
                let target = admission.intent == "open" ? admission.slots["target_id"]
                    : session.boundContext.targetAppID
                lane.dispatchResult = await cua.beginVoiceTask(admission.text, app: target,
                                             literalText: admission.slots["text"],
                                             transcriptHint: admission.text,
                                             captureID: admission.turn.id)
            }
        }
        session.onDecision = { [weak lane] admission in
            lane?.admission = admission
        }

        monitor.canBegin = { lane.armed && !lane.capturing }
        monitor.operationActive = { lane.capturing }
        monitor.onAction = { action in
            Task { @MainActor in await lane.handle(action) }
        }
        monitor.onDictationBegin = { Task { @MainActor in await lane.begin(mode: .dictation) } }
        monitor.onDictationConvert = { Task { @MainActor in lane.session.enterDictation() } }
        monitor.onInterruption = { message in lane.interrupt(message) }
        if automated {
            say("Scripted hold ready — the physical Fn tap is not part of this check.")
        } else {
            monitor.start()
            // A secure-input block clears itself once dismissed; allow the
            // physical tap time to recover without silently arming a hold.
            var tapHintShown = false
            let tapDeadline = ProcessInfo.processInfo.systemUptime + 60
            while !monitor.ready, ProcessInfo.processInfo.systemUptime < tapDeadline {
                if !tapHintShown, ProcessInfo.processInfo.systemUptime > tapDeadline - 57 {
                    say("Waiting for the Fn tap — close any secure-input app (password manager, Screen Sharing) if this stalls…")
                    tapHintShown = true
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard monitor.ready else { throw VoiceError("Fn monitor not ready: \(monitor.message)") }
            say("Fn tap ready — \(monitor.message)")
        }

        // Cold preparation is part of the contract — measure it once.
        say("Preparing local speech models (cold)…")
        let preparedAt = ProcessInfo.processInfo.systemUptime
        try await session.prewarm()
        let coldPreparationMS = (ProcessInfo.processInfo.systemUptime - preparedAt) * 1000
        say("Models ready (\(Int(coldPreparationMS)) ms cold)")
        cua.warm()

        let runAttemptsURL = results.appendingPathComponent(
            "\(automated ? "self-test" : "live")-attempts-\(runID).jsonl")
        let diagnosticURL = results.appendingPathComponent("trial-report-\(runID).json")
        guard !FileManager.default.fileExists(atPath: diagnosticURL.path) else {
            throw VoiceError("A diagnostic already exists for this run; refusing to overwrite it.")
        }
        var diagnostic = VoiceTrialReport(runID: runID, source: source,
                                          artifactSHA: artifact, executedSHA: executedArtifact)
        func attempt(_ fields: [String: JSONValue]) throws {
            var merged: [String: JSONValue] = ["run_id": .string(runID)]
            for (key, value) in fields { merged[key] = value }
            var line = try JSONEncoder().encode(JSONValue.object(merged))
            line.append(contentsOf: [UInt8(10)])
            let handle = try FileHandle(forWritingTo: attemptsURL)
            handle.seekToEndOfFile(); handle.write(line); try handle.close()
            let runHandle = try FileHandle(forWritingTo: runAttemptsURL)
            runHandle.seekToEndOfFile(); runHandle.write(line); try runHandle.close()
            diagnostic.append(merged)
            try diagnostic.save(status: "running", attemptsFile: runAttemptsURL, to: diagnosticURL)
        }
        if !FileManager.default.fileExists(atPath: attemptsURL.path) {
            FileManager.default.createFile(atPath: attemptsURL.path, contents: nil)
        }
        guard FileManager.default.createFile(atPath: runAttemptsURL.path, contents: nil) else {
            throw VoiceError("Could not create the run's immutable attempts ledger.")
        }
        try diagnostic.save(status: "running", attemptsFile: runAttemptsURL, to: diagnosticURL)
        say("Local acoustic slice only; normal semantic/realtime fallback is NOT exercised.")
        say("Diagnostic report: \(diagnosticURL.lastPathComponent). Raw transcripts stay in this Terminal only.")

        func liveContext() -> VoiceAdmissionContext {
            var context = VoiceAdmissionContext()
            context.appRoles = VoiceAdmissionContext.observedAppRoles()
            var entities = NSWorkspace.shared.runningApplications.compactMap {
                app -> VoiceAdmissionContext.Entity? in
                guard app.activationPolicy == .regular,
                      let name = app.localizedName, let id = app.bundleIdentifier else { return nil }
                return .init(name: name, id: id, canOpenLocally: true)
            }
            for directory in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                where name.hasSuffix(".app") {
                    guard let bundle = Bundle(path: directory + "/" + name), let id = bundle.bundleIdentifier,
                          !entities.contains(where: { $0.id == id }) else { continue }
                    let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? String(name.dropLast(4))
                    entities.append(.init(name: display, id: id, canOpenLocally: true))
                }
            }
            context.entities = entities
            if let front = NSWorkspace.shared.frontmostApplication,
               let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]],
               let window = rows.first(where: {
                   ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == front.processIdentifier
                       && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
               }), let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue {
                context.windowID = id
                context.targetAppID = front.bundleIdentifier
                context.targetID = "window:\(front.processIdentifier):\(id)"
                context.editableTarget = front.bundleIdentifier == textEdit
            }
            context.tasks = Set(cua.tasks.filter(\.active).map(\.id))
            context.selectedTask = context.tasks.count == 1 ? context.tasks.first : nil
            return context
        }

        func frontmost() -> (pid: Int32, bundle: String?)? {
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
        }

        /// Poll for a frontmost-app predicate; returns the mark when first observed.
        func pollFrontmost(_ bundleID: String, timeout: TimeInterval) async -> (uptime: TimeInterval, pid: Int32)? {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let front = frontmost(), front.bundle == bundleID {
                    return (ProcessInfo.processInfo.systemUptime, front.pid)
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return nil
        }

        /// Confirm a bundle never fronts inside the window — the negative proof.
        func neverFronts(_ bundleID: String, window: TimeInterval) async -> Bool {
            (await pollFrontmost(bundleID, timeout: window)) == nil
        }

        func activate(_ bundleID: String, openFile: URL? = nil) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", bundleID] + (openFile.map { [$0.path] } ?? [])
            try process.run()
            // `open -b` sends a bare reopen event — a running, windowless app
            // (TextEdit after its only document closed) fronts nothing for it.
            // NSRunningApplication.activate forces real activation; retry while
            // the launch races registration so cold starts land too.
            for _ in 0..<20 {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                    app.activate(options: [.activateAllWindows])
                }
                if await pollFrontmost(bundleID, timeout: 0.75) != nil { return }
            }
            throw VoiceError("Could not front \(bundleID) for the fixture.")
        }

        var fixtureSeq = 0
        /// Never launch the app under test in setup. Hide an existing instance
        /// and return focus to the terminal (TextEdit only for dictation).
        func resetFixture(fresh: Bool) async throws -> Int32 {
            guard !cua.tasks.contains(where: \.active) else {
                throw VoiceError("Previous task is still running; refusing to reset its fixture.")
            }
            var file: URL?
            if fresh {
                fixtureSeq += 1
                let url = results.appendingPathComponent("live-fixture-\(runID)-\(fixtureSeq).txt")
                FileManager.default.createFile(atPath: url.path, contents: Data())
                file = url
            }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: calculator) {
                app.hide()
            }
            let baseline = fresh ? textEdit : baselineApp
            try await activate(baseline, openFile: file)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while NSRunningApplication.runningApplications(withBundleIdentifier: calculator).contains(where: { !$0.isHidden }),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: calculator).contains(where: { !$0.isHidden }),
                  let front = frontmost(), front.bundle == baseline else {
                throw VoiceError("Baseline not ready: Calculator must be hidden and the instruction window frontmost.")
            }
            if fresh {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while DictationDelivery.focusedElementValue() != "",
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard DictationDelivery.focusedElementValue() == "" else {
                    throw VoiceError("TextEdit did not focus the empty trial document.")
                }
            }
            return front.pid
        }

        func wrongDispatch(_ spec: Spec) -> Bool {
            lane.dispatchCount > 0 && (spec.kind != .clearOpen
                || lane.admission?.intent != "open"
                || lane.admission?.slots["target_id"] != calculator)
        }

        func outcome(_ spec: Spec, rep: Int) async throws -> [String: JSONValue] {
            // No recorded speech exists for these paraphrases. A targeted
            // automated probe may test their real coordinator/driver effect
            // from typed input, but must not pretend it tested their ASR.
            let typedProbe = automated && spec.kind == .clearOpen && spec.id != "live-c1"
            var row: [String: JSONValue] = [
                "schema_version": .number(1), "run_id": .string(runID),
                "case_id": .string(spec.id), "repetition": .number(Double(rep)),
                "source": .string(typedProbe ? "automated-typed-no-microphone" : source),
                "input_kind": .string(typedProbe ? "typed" : (automated ? "recorded-scripted-hold" : "physical-Fn-microphone")),
                "artifact_sha256": .string(artifact),
                "provider": .string("parakeet-eou-ultra"),
                "config": .string("FluidAudio0.17.5/ms160/eou1280/whole-hold-Ultra"),
                "utterance": .string(spec.utterance), "kind": .string("\(spec.kind)"),
                "dispatch_count": .number(0), "effect_count": .number(0), "command_effect_count": .number(0),
                "wrong_critical_actions": .number(0)
            ]
            let baseline = try await resetFixture(fresh: spec.kind == .dictation)
            session.context = liveContext()
            lane.arm()
            guard lane.armed else {
                throw VoiceError(lane.failure ?? "Input is unavailable; no hold requested.")
            }
            say("  READY ▸ \(spec.id) rep \(rep) — \(spec.instruction)")
            if typedProbe {
                let now = ProcessInfo.processInfo.systemUptime
                lane.pressAt = now; lane.fnUp = now
                say("    Typed diagnostic — no microphone or physical Fn proof.")
                lane.admission = await session.submitTyped(spec.utterance, now: now)
                lane.resolve()
            } else {
                let input: Task<Void, Never>? = automated ? Task { @MainActor in
                    do { try await driveRecording(spec, lane: lane) }
                    catch { await lane.abort("Automated input failed: \(error.localizedDescription)") }
                } : nil
                await lane.waitOutcome(timeout: automated ? 30 : 90)
                input?.cancel()
            }
            if let token = lane.lastToken {
                row["turn_id"] = .string(token.id.uuidString)
                row["generation"] = .number(Double(token.generation))
            }
            row["marks"] = .object([
                "fn_down": .number(lane.pressAt), "fn_up": .number(lane.fnUp),
                "finalized": session.finalizedAt.map(JSONValue.number) ?? .null,
                "dispatch": lane.dispatchMark.map(JSONValue.number) ?? .null
            ])
            row["dispatch_count"] = .number(Double(lane.dispatchCount))
            row["wrong_critical_actions"] = .number(wrongDispatch(spec) ? 1 : 0)
            if let failure = lane.failure {
                row["status"] = .string("failed_capture_or_finalize")
                row["error"] = .string(failure)
                row["verification"] = .object(["kind": .string("capture_failure"), "passed": .bool(false)])
                return row
            }
            let admission = lane.admission
            let token = admission?.turn ?? lane.lastToken
            row["turn_id"] = .string((token?.id ?? UUID()).uuidString)
            row["generation"] = .number(Double(token?.generation ?? 0))
            let fnUp = lane.fnUp > 0 ? lane.fnUp : lane.pressAt
            row["marks"] = .object([
                "fn_up": .number(fnUp),
                "dispatch": lane.dispatchMark.map(JSONValue.number) ?? .null,
                "effect": .null
            ])
            if let admission {
                row["actual_route"] = .string(admission.route.rawValue)
                row["actual_intent"] = .string(admission.intent)
                row["transcript_sha256"] = .string(sha256Hex(admission.text))
                row["transcript_word_count"] = .number(Double(admission.text.split(whereSeparator: \.isWhitespace).count))
            }
            row["dispatch_count"] = .number(Double(lane.dispatchCount))

            switch spec.kind {
            case .clearOpen:
                guard let admission, admission.route == .local, admission.intent == "open",
                      admission.slots["target_id"] == calculator, lane.dispatchCount == 1,
                      let dispatch = lane.dispatchMark else {
                    row["status"] = .string("failed"); row["error"] =
                        .string("expected one local dispatch, got route=\(admission?.route.rawValue ?? "none") dispatches=\(lane.dispatchCount)")
                    row["verification"] = .object(["kind": .string("frontmost_pid"), "passed": .bool(false)])
                    return row
                }
                // beginVoiceTask returns "started". Wait for both the effect
                // and the worker to settle before a later fixture may hide it.
                var observed: (uptime: TimeInterval, pid: Int32)?
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if observed == nil, let front = frontmost(), front.bundle == calculator {
                        observed = (ProcessInfo.processInfo.systemUptime, front.pid)
                    }
                    let work = cua.tasks.filter { $0.captureID == admission.turn.id }
                    if !work.isEmpty, work.allSatisfy({ !$0.active }) { break }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                let work = cua.tasks.filter { $0.captureID == admission.turn.id }
                row["effect_count"] = .number(observed == nil ? 0 : 1)
                if let observed {
                    row["observed_foreground"] = .object([
                        "kind": .string("frontmost_pid"), "app_id": .string(calculator),
                        "pid": .number(Double(observed.pid)), "uptime": .number(observed.uptime)
                    ])
                    row["marks"] = .object([
                        "fn_up": .number(fnUp), "dispatch": .number(dispatch),
                        "effect": .number(observed.uptime),
                        "finalized": session.finalizedAt.map(JSONValue.number) ?? .null
                    ])
                }
                guard work.count == 1, work.allSatisfy({ !$0.active }) else {
                    work.filter(\.active).forEach { cua.cancel($0.id) }
                    row["status"] = .string("failed")
                    row["error"] = .string("Dispatch did not finish: \(work.first?.message ?? lane.dispatchResult ?? "no task result")")
                    row["verification"] = .object(["kind": .string("task_completion"), "passed": .bool(false)])
                    return row
                }
                row["task_message"] = .string(work[0].message)
                row["task_window_diagnostics"] = .array(work[0].history
                    .filter { $0.hasPrefix("Window inventory: ") }.map(JSONValue.string))
                guard work[0].outcome == .done || work[0].outcome == .alreadyDone else {
                    row["status"] = .string("failed")
                    row["error"] = .string(completionFailureMessage(
                        foregroundObserved: observed != nil, taskMessage: work[0].message))
                    row["verification"] = .object(["kind": .string("task_completion"), "passed": .bool(false),
                                                  "foreground_observed": .bool(observed != nil)])
                    return row
                }
                guard let observed else {
                    row["status"] = .string("failed")
                    row["error"] = .string("Calculator did not front. Driver: \(work.first?.message ?? "no result")")
                    row["verification"] = .object(["kind": .string("frontmost_pid"), "passed": .bool(false),
                                                  "app_id": .string(calculator),
                                                  "baseline_frontmost_pid": .number(Double(baseline))])
                    return row
                }
                row["status"] = .string("ok")
                row["effect_count"] = .number(1)
                row["marks"] = .object(["fn_up": .number(lane.fnUp), "dispatch": .number(dispatch),
                                        "effect": .number(observed.uptime),
                                        "finalized": session.finalizedAt.map(JSONValue.number) ?? .null])
                row["verification"] = .object([
                    "kind": .string("frontmost_pid"), "passed": .bool(true),
                    "app_id": .string(calculator), "pid": .number(Double(observed.pid)),
                    "baseline_frontmost_pid": .number(Double(baseline))])

            case .cancelDuringFinish:
                // Esc mid-hold → cancelCapture → no admission must exist.
                let noDispatch = await neverFronts(calculator, window: 3)
                let passed = admission == nil && lane.dispatchCount == 0 && noDispatch
                row["status"] = .string(passed ? "ok" : "failed")
                if !passed { row["error"] = .string("cancel produced admission=\(admission?.route.rawValue ?? "nil") dispatches=\(lane.dispatchCount)") }
                row["verification"] = .object(["kind": .string("no_dispatch"), "passed": .bool(passed)])

            case .dictation:
                guard let admission, admission.route == .dictation, lane.dispatchCount == 0 else {
                    row["status"] = .string("failed")
                    row["error"] = .string("expected dictation route without dispatch, got route=\(admission?.route.rawValue ?? "none") dispatches=\(lane.dispatchCount)")
                    row["verification"] = .object(["kind": .string("owned_literal_delivery"), "passed": .bool(false)])
                    return row
                }
                try await DictationDelivery().deliver(admission.text)
                var readback: String?
                for _ in 0..<40 {
                    readback = DictationDelivery.focusedElementValue()
                    if readback == admission.text { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let deliveredSHA = readback.map(sha256Hex)
                let transcriptSHA = sha256Hex(admission.text)
                let noDispatch = await neverFronts(calculator, window: 2)
                let passed = deliveredSHA == transcriptSHA && noDispatch
                row["status"] = .string(passed ? "ok" : "failed")
                if !passed { row["error"] = .string("readback=\(deliveredSHA ?? "nil") transcript=\(transcriptSHA) calcFronted=\(!noDispatch)") }
                row["verification"] = .object([
                    "kind": .string("owned_literal_delivery"), "passed": .bool(passed),
                    "delivered_sha256": .string(deliveredSHA ?? ""),
                    "transcript_sha256": .string(transcriptSHA),
                    "fixture_run_id": .string(runID)])

            case .negated, .confusable:
                let admitted = admission.map { [$0.route.rawValue] } ?? ["none"]
                let safeRoute = admission.map { $0.route == .clarify || $0.route == .refuse } ?? false
                let noDispatch = await neverFronts(calculator, window: 3)
                let passed = safeRoute && lane.dispatchCount == 0 && noDispatch
                row["status"] = .string(passed ? "ok" : "failed")
                if !passed {
                    row["error"] = .string("route=\(admitted) dispatches=\(lane.dispatchCount)")
                    if lane.dispatchCount > 0 { row["wrong_critical_actions"] = .number(1) }
                }
                row["verification"] = .object(["kind": .string("no_dispatch"), "passed": .bool(passed)])
            }
            return row
        }

        func checked(_ spec: Spec, rep: Int, phase: String) async throws -> [String: JSONValue]? {
            var attemptNo = 0
            while true {
                attemptNo += 1
                var row: [String: JSONValue]
                do { row = try await outcome(spec, rep: rep) }
                catch {
                    row = ["case_id": .string(spec.id), "repetition": .number(Double(rep)),
                           "status": .string("failed_fixture"), "error": .string(error.localizedDescription),
                           "source": .string(source), "artifact_sha256": .string(artifact),
                           "dispatch_count": .number(Double(lane.dispatchCount)),
                           "wrong_critical_actions": .number(wrongDispatch(spec) ? 1 : 0)]
                }
                row["attempt"] = .number(Double(attemptNo))
                row["phase"] = .string(phase)
                row["latency_spans"] = .array(lane.latencySpans)
                try attempt(row)
                if row["status"]?.string == "ok" {
                    say("  ✓ \(phase) \(spec.id) rep \(rep) — verified")
                    return row
                }
                say("  ✗ \(phase): \(row["error"]?.string ?? "verification failed")")
                say(VoiceTrialReport.consoleFailure(row, heard: lane.admission?.text))
                if automated || phase != "warmup" || lane.inputFailure != nil || row["wrong_critical_actions"]?.integer == 1 {
                    try diagnostic.save(status: "stopped_on_failure", attemptsFile: runAttemptsURL, to: diagnosticURL)
                    say("  Run stopped; diagnostic saved to \(diagnosticURL.lastPathComponent). No acceptance pass.")
                    return nil
                }
                try await activate(baselineApp)
                say("  Press Return to retry this case, or type a then Return to abort.")
                let answer = await readAnswer()
                guard answer == "" || answer == "r" else {
                    try diagnostic.save(status: "stopped_on_failure", attemptsFile: runAttemptsURL, to: diagnosticURL)
                    return nil
                }
            }
        }

        say("Cold turn — first inference after measured model preparation.")
        guard let cold = try await checked(clearSpecs[0], rep: 1, phase: "cold") else {
            return 1
        }
        var warmups: [JSONValue] = []
        // Warmups use exactly the same timeout, dispatch/effect verification
        // and retry path as scored cases. A failed warmup cannot silently pass.
        for warmup in 1...2 {
            say("Warmup \(warmup)/2")
            guard let row = try await checked(clearSpecs[0], rep: warmup, phase: "warmup") else {
                say("Stopped during warmup; inspect \(attemptsURL.lastPathComponent).")
                return 1
            }
            warmups.append(.object(row))
        }

        var rows: [JSONValue] = []
        var aborted = false
        // Existing recorded speech covers open, withdrawal, cancel, dictation
        // and confusable controls. It does not prove the three other spoken
        // paraphrases or the physical microphone/keyboard.
        let withdrawal = Spec(id: "auto-withdraw", kind: .negated,
            utterance: "open Calculator actually do not open it", instruction: "Recorded withdrawal.")
        let specs: [Spec]
        if automated, let only, let selected = clearSpecs.first(where: { $0.id == only }),
           selected.id != "live-c1" {
            specs = [selected]
        } else {
            specs = automated
                ? [clearSpecs[0], withdrawal] + Array(controlSpecs.dropFirst())
                : clearSpecs + controlSpecs
        }
        outer: for spec in specs {
            if let only, spec.id != only { continue }
            let reps = spec.kind == .clearOpen ? 5 : 1
            for rep in 1...reps {
                guard let row = try await checked(spec, rep: rep, phase: "scored") else {
                    aborted = true; break outer
                }
                rows.append(.object(row))
            }
        }
        if aborted {
            say("Local trial stopped. Failure report saved to \(diagnosticURL.lastPathComponent); normal-app routing was not tested.")
            return 1
        }
        guard !rows.isEmpty else {
            try diagnostic.save(status: "stopped_on_failure", attemptsFile: runAttemptsURL, to: diagnosticURL)
            throw VoiceError("No cases selected.")
        }

        var humanConfirmed = false
        if !automated {
            try await activate(baselineApp)
            say("\n\(rows.count) selected trials passed verification. Type 'yes' only if you performed the Fn holds, speech, and observed the app effects:")
            humanConfirmed = await readAnswer() == "yes"
        }

        let data = JSONValue.object([
            "schema_version": .number(1), "source": .string(source), "run_id": .string(runID),
            "artifact_sha256": .string(artifact),
            "executed_artifact_sha256": .string(executedArtifact),
            "install_receipt_sha256": installReceiptSHA.map(JSONValue.string) ?? .null,
            "provider": .string("parakeet-eou-ultra"),
            "config": .string("FluidAudio0.17.5/ms160/eou1280/whole-hold-Ultra"),
            "cold_preparation_ms": .number(coldPreparationMS),
            "cold_preparation_started": .number(preparedAt),
            "cold_ready_at": .number(preparedAt + coldPreparationMS / 1000),
            "cold": .object(cold), "warmups": .array(warmups),
            "attempts_file": .string(runAttemptsURL.lastPathComponent),
            "attempts_sha256": .string(try digest(runAttemptsURL)),
            "warmup_turns": .number(2),
            "human_confirmed": .bool(humanConfirmed),
            "remote_live_authorized": .bool(false), "remote_live_validated": .bool(false),
            "fixture": .object(["app": .string(baselineApp), "run_id": .string(runID)]),
            "rows": .array(rows)
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: output, options: .atomic)
        try diagnostic.save(status: automated || humanConfirmed ? "complete_pending_verification" : "complete_unattested",
                            attemptsFile: runAttemptsURL, to: diagnosticURL)
        await microphone.stop()
        say("Wrote \(output.lastPathComponent): \(rows.count) rows, human_confirmed=\(humanConfirmed); no remote validation.")
        return automated || humanConfirmed ? 0 : 2
    }

    private static func readAnswer() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
    }

    @MainActor
    private final class MicrophonePreflightState {
        var interrupted = false
    }

    private static func microphonePreflight() async throws -> Int32 {
        let argv = CommandLine.arguments
        let runID = UUID().uuidString
        let output = results.appendingPathComponent("microphone-preflight-\(runID).json")
        let build = try loadJSON(results.appendingPathComponent("build.json"))
        guard let sources = build["source_hashes"]?.object else { throw VoiceError("Missing build source binding.") }
        for (path, expected) in sources {
            guard try digest(root.appendingPathComponent(path)) == expected.string else {
                throw VoiceError("Source changed since this build; rebuild before the microphone preflight.")
            }
        }
        let microphone = MicrophoneInput()
        let state = MicrophonePreflightState()
        var report: [String: JSONValue] = [
            "schema_version": .number(1), "run_id": .string(runID),
            "report_kind": .string("physical_microphone_preflight_not_acceptance"),
            "phase_acceptance": .bool(false), "executor_attempts": .number(0),
            "audio_saved": .bool(false), "asr_used": .bool(false),
            "executed_artifact_sha256": .string(try digest(URL(fileURLWithPath: argv[0]))),
            "source_artifact_sha256": build["artifact_sha256"] ?? .null,
            "status": .string("failed")
        ]
        do {
            guard Permission.microphone.isGranted else {
                throw VoiceError("Microphone permission is not granted; no input was started.")
            }
            let began = ProcessInfo.processInfo.systemUptime
            let hardware = try await microphone.prepare(device: MicrophoneCatalog.resolve(uid: nil)) {
                Task { @MainActor in state.interrupted = true }
            }
            let first = microphone.gate.snapshot()
            report["ready_ms"] = .number((ProcessInfo.processInfo.systemUptime - began) * 1000)
            report["first_frames"] = .number(Double(hardware.firstFrames))
            report["startup_recoveries"] = .number(Double(hardware.startupRecoveries))
            let observationBegan = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - observationBegan < 3 {
                guard !state.interrupted else { throw VoiceError("Microphone stopped during the setup observation.") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let last = microphone.gate.snapshot()
            let now = mach_absolute_time()
            let age = AVAudioTime.seconds(forHostTime: max(now, last.lastHostTime) - min(now, last.lastHostTime))
            guard !state.interrupted, hardware.firstFrames > 0, last.frames > first.frames, age < 0.5 else {
                throw VoiceError("The microphone did not retain live frame flow through setup.")
            }
            report["observed_frames"] = .number(Double(last.frames - first.frames))
            report["last_frame_age_ms"] = .number(age * 1000)
            report["observation_ms"] = .number((ProcessInfo.processInfo.systemUptime - observationBegan) * 1000)
            report["status"] = .string("passed")
        } catch {
            report["failure"] = .string(error is CancellationError ? "cancelled" : "input_not_ready")
            report["detail"] = .string(error.localizedDescription)
        }
        await microphone.stop()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(JSONValue.object(report)).write(to: output, options: .atomic)
        say("Microphone preflight \(report["status"]?.string ?? "failed"): \(output.lastPathComponent). No command admission or audio recording.")
        return report["status"]?.string == "passed" ? 0 : 1
    }

    /// Uses only previously confirmed, local recordings. Gold text is never
    /// supplied to the transcriber; the real provider decodes the PCM.
    private static func recording(_ id: String) throws -> URL {
        let directory = results.appendingPathComponent("audio")
        let manifest = try loadJSON(directory.appendingPathComponent("manifest.json"))
        guard let row = manifest["recordings"]?.array?.last(where: {
            $0["id"]?.string == id && $0["confirmed"]?.bool == true && $0["status"]?.string == "ok"
        }), let name = row["wav"]?.string, !name.contains("/") else {
            throw VoiceError("Missing confirmed local recording \(id).")
        }
        return directory.appendingPathComponent(name)
    }

    /// Recordings enter the same gate/converter/consumer as a human capture;
    /// a scripted hold replaces OS Fn events so synthetic HID state cannot
    /// spuriously trigger the physical-key health watchdog. Never live.json.
    private static func driveRecording(_ spec: Spec, lane: Lane) async throws {
        let id = spec.kind == .confusable ? "h02" : (spec.kind == .negated ? "h16" : "h15")
        let file = try AVAudioFile(forReading: recording(id))
        guard file.processingFormat == lane.hardwareFormat else {
            throw VoiceError("Self-test recordings must use the same PCM format.")
        }
        await lane.begin(mode: spec.kind == .dictation ? .dictation : .command)
        guard lane.feed != nil else { throw VoiceError("Scripted hold did not begin capture.") }
        let start = ProcessInfo.processInfo.systemUptime
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(320, file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                throw LocalSpeechError.captureLoss
            }
            try file.read(into: buffer, frameCount: count)
            lane.microphone.gate.append(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
            let until = start + Double(file.framePosition) / file.processingFormat.sampleRate
            let remaining = until - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        if spec.kind == .cancelDuringFinish {
            await lane.handle(.cancel)
        } else {
            await lane.handle(.finish)
        }
    }

    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func loadJSON(_ url: URL) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
}

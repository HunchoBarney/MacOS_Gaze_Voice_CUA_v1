import AVFoundation
import CryptoKit
import Darwin
import FluidAudio
import Foundation
import JevVoiceCore

/// Real files -> production provider/session -> recorded admission boundary.
/// Never boots the app, opens a socket, acquires a microphone, or actuates a Mac.
@MainActor
enum VoiceReplay {
    nonisolated static func main() -> Never {
        Task { @MainActor in
            do {
                let code = CommandLine.arguments.contains("--p3-record-holdouts")
                    ? try await recordHoldouts() : try await run()
                exit(code)
            }
            catch {
                FileHandle.standardError.write(Data("P3 replay failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func run() async throws -> Int32 {
        let argv = CommandLine.arguments
        func argument(_ name: String) throws -> String {
            guard let index = argv.firstIndex(of: name), argv.indices.contains(index + 1) else {
                throw VoiceError("Missing replay argument: " + name)
            }
            return argv[index + 1]
        }
        let manifestURL = URL(fileURLWithPath: try argument("--manifest")).standardizedFileURL
        let sourceRoot = URL(fileURLWithPath: try argument("--recordings-root")).standardizedFileURL
        let output = URL(fileURLWithPath: try argument("--out")).standardizedFileURL
        guard output.deletingLastPathComponent() == root.appendingPathComponent(".agent/results/P3").standardizedFileURL else {
            throw VoiceError("Replay output must be phase-owned.")
        }
        let manifest = try load(manifestURL)
        let regressions = manifest["acoustic_regression_labels"]?.array ?? []
        let holdout = manifest["acoustic_holdout"]?.array ?? []
        guard regressions.count == 15, holdout.count == 20 else { throw VoiceError("Invalid frozen audio population.") }
        let provider = LocalTranscriber.shared
        let runID = UUID().uuidString
        let artifact = try digest(URL(fileURLWithPath: argv[0]))
        let sourceSHA = try digest(root.appendingPathComponent("Sources/JevVoice/Intelligence/LocalTranscriber.swift"))
        var missing: [String] = [], rows: [JSONValue] = []
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        do {
            try await withVoiceDeadline(until: preparationStarted + 180) { try await provider.prepare() }
        } catch {
            let blocked = JSONValue.object([
                "schema_version": .number(1), "run_id": .string(runID),
                "status": .string("blocked_provider_unavailable"), "artifact_sha256": .string(artifact),
                "missing": .array((regressions + holdout).compactMap { $0["id"] }),
                "regression_count": .number(15), "holdout_count": .number(20),
                "rows": .array([]), "wrong_critical_actions": .number(0)
            ])
            try JSONEncoder().encode(blocked).write(to: output, options: .atomic)
            return 2
        }
        let preparationMS = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
        let assets = try assetFingerprint()
        let regressionRoot = URL(fileURLWithPath: manifest["acoustic_regression"]?["recordings_root"]?.string ?? "")
        let regressionIndex = (try? load(regressionRoot.appendingPathComponent("manifest.json"))) ?? .null
        let suppliedIndex = (try? load(sourceRoot.appendingPathComponent("manifest.json"))) ?? .null
        let privateRoot = root.appendingPathComponent(".agent/results/P3/audio")
        let privateIndex = (try? load(privateRoot.appendingPathComponent("manifest.json"))) ?? .null
        var wrong = 0, failed = 0, clearTotal = 0, clearCorrect = 0, extraClarifications = 0
        for label in regressions + holdout {
            guard let id = label["id"]?.string, let population = label["population"]?.string,
                  let contextID = label["context"]?.string else { throw VoiceError("Unlabeled audio case.") }
            if population == "clear_autonomous" { clearTotal += 1 }
            let regression = id.hasPrefix("p")
            let indexes = regression
                ? [(sourceRoot, suppliedIndex), (regressionRoot, regressionIndex)]
                : [(sourceRoot, suppliedIndex), (privateRoot, privateIndex)]
            var recording: (URL, String)?
            for (directory, index) in indexes {
                if let entry = index["recordings"]?.array?.first(where: { $0["id"]?.string == id }),
                   entry["confirmed"]?.bool == true, entry["status"]?.string == "ok",
                   let path = entry["wav"]?.string {
                    let url = directory.appendingPathComponent(path).standardizedFileURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        recording = (url, entry["prompt"]?.string ?? label["utterance"]?.string ?? "")
                        break
                    }
                }
            }
            guard let recording else {
                missing.append(id)
                rows.append(.object(["schema_version": .number(1), "run_id": .string(runID),
                                     "case_id": .string(id), "source": .string("recorded"),
                                     "population": .string(population), "status": .string("blocked_missing_recording")]))
                continue
            }
            var calls: [VoiceAdmission] = []
            let session = LocalSpeechSession(provider: provider) { calls.append($0) }
            session.context = try fixtureContext(contextID, manifest: manifest)
            var firstPartial: TimeInterval?
            session.onPartial = { _, text in
                if !text.isEmpty, firstPartial == nil { firstPartial = ProcessInfo.processInfo.systemUptime }
            }
            let captureStarted = ProcessInfo.processInfo.systemUptime
            var row: [String: JSONValue] = [
                "schema_version": .number(1), "run_id": .string(runID), "case_id": .string(id),
                "source": .string("recorded"), "population": .string(population),
                "source_sha256": .string(try digest(recording.0)), "artifact_sha256": .string(artifact),
                "provider_source_sha256": .string(sourceSHA), "provider": .string("parakeet-eou-ultra"),
                "model_assets_sha256": .string(assets),
                "config": .string("FluidAudio0.17.5/ms160/eou1280/whole-hold-Ultra"),
                "expected_route": label["route"] ?? .null, "expected_slots": label["critical_slots"] ?? .object([:]),
                "effect_count": .number(0), "verification_kind": .string("production-admission-boundary-not-physical")
            ]
            do {
                let token = try await session.beginCapture(id: UUID(), mode: .command, now: captureStarted)
                let streamed = try streamFile(recording.0, session: session, turn: token)
                let sealed = try await streamed.producer.value
                let released = ProcessInfo.processInfo.systemUptime
                let admission = try await session.finishCapture(
                    token, acceptedFrames: sealed.count, releasedAt: released,
                    capturedSeconds: streamed.seconds,
                    drain: { try await streamed.consumer.value })
                guard let admission else { throw LocalSpeechError.emptyFinal }
                let routeCorrect = admission.route.rawValue == label["route"]?.string
                let countCorrect = calls.count == label["dispatch_count"]?.integer
                let criticalCorrect = slotsMatch(label["critical_slots"] ?? .object([:]), admission: admission)
                let passed = routeCorrect && countCorrect && (population != "clear_autonomous" || criticalCorrect)
                if !passed { failed += 1 }
                if !passed, !calls.isEmpty { wrong += 1 }
                if population == "clear_autonomous" {
                    if passed { clearCorrect += 1 }
                    if admission.route == .clarify || admission.route == .refuse { extraClarifications += 1 }
                }
                row["status"] = .string(passed ? "ok" : "failed")
                row["actual_route"] = .string(admission.route.rawValue)
                row["actual_intent"] = .string(admission.intent)
                row["actual_slots"] = .object(admission.slots.mapValues(JSONValue.string))
                row["actual_dispatches"] = .number(Double(calls.count))
                row["turn_id"] = .string(token.id.uuidString)
                row["generation"] = .number(Double(token.generation))
                row["transcript_sha256"] = .string(SHA256.hash(data: Data(admission.text.utf8)).map { String(format: "%02x", $0) }.joined())
                row["word_edits"] = .number(Double(wordEdits(recording.1, admission.text)))
                row["reference_words"] = .number(Double(words(recording.1).count))
                row["critical_slots_match"] = .bool(criticalCorrect)
                row["verification_passed"] = .bool(passed)
                row["marks"] = .object(["capture_start": .number(captureStarted), "fn_up": .number(released),
                                        "first_frame": .number(sealed.firstFrame),
                                        "authoritative_final": .number(session.finalizedAt ?? released),
                                        "first_partial_callback": firstPartial.map(JSONValue.number) ?? .null])
            } catch {
                failed += 1
                if let token = session.gate.token { await session.cancelCapture(token) }
                row["status"] = .string("failed_capture_or_finalize")
                row["actual_dispatches"] = .number(Double(calls.count))
                row["verification_passed"] = .bool(false)
                row["error"] = .string("\(type(of: error)): \(error.localizedDescription)")
            }
            rows.append(.object(row))
        }
        let data = JSONValue.object([
            "schema_version": .number(1), "run_id": .string(runID), "rows": .array(rows),
            "manifest_sha256": .string(try digest(manifestURL)), "artifact_sha256": .string(artifact),
            "model_assets_sha256": .string(assets),
            "regression_count": .number(15), "holdout_count": .number(20), "missing": .array(missing.map(JSONValue.string)),
            "wrong_critical_actions": .number(Double(wrong)), "failed_available_cases": .number(Double(failed)),
            "clear_total": .number(Double(clearTotal)), "clear_correct": .number(Double(clearCorrect)),
            "extra_clarifications": .number(Double(extraClarifications)), "preparation_ms": .number(preparationMS),
            "physical_effects_verified": .bool(false), "remote_live_verified": .bool(false)
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: output, options: .atomic)
        FileHandle.standardOutput.write(Data("P3 replay: \(rows.count - missing.count)/35 available; \(failed) failed; \(missing.count) missing. No physical/server proof.\n".utf8))
        if failed > 0 { return 1 }
        return missing.isEmpty ? 0 : 2
    }
}

private extension VoiceReplay {
    static func say(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func recordHoldouts() async throws -> Int32 {
        guard isatty(STDIN_FILENO) == 1 else { throw VoiceError("Recording needs an interactive terminal.") }
        let manifest = try load(root.appendingPathComponent("Tests/Fixtures/P3/manifest.json"))
        let phrases = manifest["acoustic_holdout"]?.array ?? []
        guard phrases.count == 20 else { throw VoiceError("The frozen held-out population is missing.") }
        let directory = root.appendingPathComponent(".agent/results/P3/audio").standardizedFileURL
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent()
            == root.appendingPathComponent(".agent/results/P3").resolvingSymlinksInPath() else {
            throw VoiceError("Private recording directory must be phase-owned.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("manifest.json")
        var recordings = (try? load(indexURL))?["recordings"]?.array ?? []
        let argv = CommandLine.arguments
        let only = argv.firstIndex(of: "--only").flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
        if let only, !phrases.contains(where: { $0["id"]?.string == only }) { throw VoiceError("Unknown held-out fixture ID.") }
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let permitted = authorized ? true : await AVCaptureDevice.requestAccess(for: .audio)
        guard permitted else {
            throw VoiceError("Microphone permission is required for this explicitly requested recorder.")
        }
        say("20 real held-out utterances. Enter starts; capture stops automatically.")
        say("After each: p + Enter plays, Enter keeps, r + Enter retries, q + Enter quits. Old takes are preserved.")
        for phrase in phrases {
            guard let id = phrase["id"]?.string, let prompt = phrase["utterance"]?.string else { throw VoiceError("Unlabeled fixture.") }
            if let only, id != only { continue }
            if only == nil, let saved = recordings.first(where: { $0["id"]?.string == id }),
               saved["confirmed"]?.bool == true, let path = saved["wav"]?.string,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) { continue }
            var accepted = false
            while !accepted {
                say("\n\(id): \(prompt)")
                if let instruction = phrase["recording_instruction"]?.string { say("Instruction: " + instruction) }
                say("Enter when ready, or q + Enter to quit:")
                guard let input = readLine(), input.lowercased() != "q" else { return 2 }
                tcflush(STDIN_FILENO, TCIFLUSH)
                let seconds: Double = id == "h16" ? 10 : 6
                let stem = id + "-" + UUID().uuidString
                let native = directory.appendingPathComponent(stem + ".caf")
                let wav = directory.appendingPathComponent(stem + ".wav")
                let recorder = try AVAudioRecorder(url: native, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ])
                guard recorder.prepareToRecord(), recorder.record(forDuration: seconds) else {
                    throw VoiceError("Native microphone recording could not start.")
                }
                say("REC - speak now (\(Int(seconds)) seconds).")
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                recorder.stop()
                tcflush(STDIN_FILENO, TCIFLUSH)
                let samples = try AudioConverter().resampleAudioFile(native)
                let duration = Double(samples.count) / 16_000
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                guard duration >= seconds - 0.3, duration <= seconds + 0.3, peak >= 0.005 else {
                    say("Capture was truncated or too quiet. It will not be accepted; retry.")
                    continue
                }
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { throw LocalSpeechError.captureLoss }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { if let base = $0.baseAddress { channel.update(from: base, count: $0.count) } }
                do {
                    let file = try AVAudioFile(forWriting: wav, settings: format.settings)
                    try file.write(from: buffer)
                }
                say("Verified \(String(format: "%.2f", duration))s of saved audio.")
                var retry = false
                while !accepted, !retry {
                    say("Enter=keep, p + Enter=listen, r + Enter=retry, q + Enter=quit:")
                    guard let decision = readLine() else { return 2 }
                    switch decision.lowercased() {
                    case "q": return 2
                    case "r": retry = true
                    case "p":
                        let player = try AVAudioPlayer(contentsOf: wav)
                        say("Playing \(id) through the current system output...")
                        guard player.play() else { throw VoiceError("Playback could not start.") }
                        while player.isPlaying { try await Task.sleep(nanoseconds: 100_000_000) }
                        say("Playback finished.")
                    case "":
                        recordings.removeAll { $0["id"]?.string == id }
                        recordings.append(.object([
                            "id": .string(id), "prompt": .string(prompt), "wav": .string(wav.lastPathComponent),
                            "confirmed": .bool(true), "status": .string("ok"), "sample_rate": .number(16_000),
                            "duration_s": .number(duration), "recorded_at": .string(ISO8601DateFormatter().string(from: Date())),
                            "source": .string("native-default-microphone-not-product-Fn")
                        ]))
                        let index = JSONValue.object(["schema_version": .number(1), "recordings": .array(recordings)])
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(index).write(to: indexURL, options: .atomic)
                        accepted = true
                    default: continue
                    }
                }
            }
        }
        say("Confirmed \(recordings.count)/20 held-out clips. No ASR inference or product action was performed.")
        return 0
    }

    struct ReplayStream {
        let producer: Task<(count: Int, firstFrame: TimeInterval), Error>
        let consumer: Task<Void, Error>
        /// Whole-clip seconds — finishCapture budgets decode for queued tail
        /// frames too, so the file's length is the sealed total, not the
        /// already-consumed prefix.
        let seconds: Double
    }

    static func streamFile(_ url: URL, session: LocalSpeechSession, turn: VoiceTurnToken) throws -> ReplayStream {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.channelCount == 1, file.length > 0,
              Double(file.length) / file.processingFormat.sampleRate <= 60 else {
            throw LocalSpeechError.captureLoss
        }
        let (stream, continuation) = AsyncThrowingStream<VoicePCMFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(128))
        let consumer = Task {
            var sequence = 0
            for try await frame in stream {
                try Task.checkCancellation()
                try await session.consume(frame, sequence: sequence, turn: turn, retainRemote: false)
                sequence += 1
            }
        }
        let producer = Task { () async throws -> (count: Int, firstFrame: TimeInterval) in
            let started = ProcessInfo.processInfo.systemUptime
            var count = 0
            do {
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let frames = AVAudioFrameCount(min(2560, file.length - file.framePosition))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                        throw LocalSpeechError.captureLoss
                    }
                    try file.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { throw LocalSpeechError.captureLoss }
                    let frame = try VoicePCMFrame(copying: buffer)
                    if case .dropped = continuation.yield(frame) { throw LocalSpeechError.captureLoss }
                    count += 1
                    let until = started + Double(file.framePosition) / file.processingFormat.sampleRate
                    let delay = until - ProcessInfo.processInfo.systemUptime
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                }
                continuation.finish()
                return (count, started)
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }
        return ReplayStream(producer: producer, consumer: consumer,
                            seconds: Double(file.length) / file.processingFormat.sampleRate)
    }

    static func fixtureContext(_ id: String, manifest: JSONValue) throws -> VoiceAdmissionContext {
        guard let value = manifest["contexts"]?[id] else { throw VoiceError("Unknown frozen context.") }
        var context = VoiceAdmissionContext()
        context.targetID = value["target_id"]?.string
        context.targetAppID = value["app_id"]?.string
        context.windowID = value["window_id"]?.integer
        context.editableTarget = value["editable_target"]?.bool ?? false
        context.entities = (value["entities"]?.array ?? []).compactMap {
            guard let name = $0["name"]?.string, let id = $0["id"]?.string else { return nil }
            return .init(name: name, id: id, canOpenLocally: $0["can_open_locally"]?.bool ?? false)
        }
        context.tasks = Set((value["tasks"]?.array ?? []).compactMap { $0["task_id"]?.string.flatMap(UUID.init(uuidString:)) })
        context.selectedTask = value["selected_task"]?.string.flatMap(UUID.init(uuidString:))
        return context
    }

    static func slotsMatch(_ expected: JSONValue, admission: VoiceAdmission) -> Bool {
        for (name, value) in expected.object ?? [:] {
            let key = name == "target" ? "target_id" : name
            let actual = admission.slots[key]
            if let keys = value.array?.compactMap(\.string) {
                guard actual == keys.joined(separator: "+") else { return false }
            } else if let text = value.string {
                guard actual?.lowercased() == text.lowercased() else { return false }
            } else if let integer = value.integer {
                guard actual == String(integer) else { return false }
            } else { return false }
        }
        return true
    }

    static func load(_ url: URL) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func assetFingerprint() throws -> String {
        var records: [String] = []
        for relative in [Repo.parakeetUltra.folderName, "parakeet-eou-streaming/160ms"] {
            let directory = LocalModelPaths.root.appendingPathComponent(relative)
            guard let iterator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                throw LocalSpeechError.unavailable
            }
            for case let url as URL in iterator {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let name = String(url.path.dropFirst(LocalModelPaths.root.path.count))
                records.append(name + ":" + (try digest(url)))
            }
        }
        guard !records.isEmpty else { throw LocalSpeechError.unavailable }
        return SHA256.hash(data: Data(records.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func words(_ text: String) -> [String] {
        VoiceAdmissionPolicy.normalized(text).split(separator: " ").map(String.init)
    }

    static func wordEdits(_ reference: String, _ actual: String) -> Int {
        let a = words(reference), b = words(actual)
        var previous = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var current = [i + 1]
            for (j, other) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (word == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

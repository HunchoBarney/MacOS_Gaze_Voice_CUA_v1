import AVFoundation
import Carbon
import Darwin
import Foundation
import JevVoiceCore
import Synchronization
import XCTest
@testable import JevVoice

final class NativeSpeechTailReplayTests: XCTestCase {
    private struct Fixture {
        let pcm: [VoicePCMFrame]
        let sourceRate: Double
        let sourceFrames: Int64
    }

    private actor PartialGate {
        private var blocked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func setBlocked(_ value: Bool) {
            blocked = value
            guard !value else { return }
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }

        func wait() async {
            guard blocked else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private final class Evidence: Sendable {
        private let storage = Mutex<[UUID: [VoiceSpeechDiagnostic]]>([:])

        func append(_ event: VoiceSpeechDiagnostic) {
            storage.withLock { $0[event.turn, default: []].append(event) }
        }

        func events(_ turn: UUID) -> [VoiceSpeechDiagnostic] {
            storage.withLock { $0[turn] ?? [] }
        }

        func has(_ turn: UUID, _ stage: String) -> Bool {
            storage.withLock { $0[turn]?.contains { $0.stage == stage } == true }
        }
    }

    @MainActor
    private func frames(_ audio: URL) async throws -> Fixture {
        let source = try AVAudioFile(forReading: audio)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 24_000, channels: 1, interleaved: true))
        let feed = try ConvertedAudioFeed(input: source.processingFormat, output: format)
        let consumer = Task { @MainActor in
            var result: [VoicePCMFrame] = []
            for try await buffer in feed.stream { result.append(try VoicePCMFrame(copying: buffer)) }
            return result
        }
        defer { feed.finish(); consumer.cancel() }
        let length = AVAudioFramePosition(source.processingFormat.sampleRate * 2.9006875)
        guard source.length >= length else { throw LocalSpeechError.tooShort }
        while source.framePosition < length {
            let count = AVAudioFrameCount(min(4096, length - source.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count))
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count else { throw LocalSpeechError.captureLoss }
            feed.append(buffer)
            await Task.yield()
        }
        feed.finish()
        let result = try await consumer.value
        XCTAssertEqual(result.count, feed.emittedFrameCount())
        XCTAssertGreaterThan(result.reduce(0) { $0 + $1.frames }, 48_000)
        XCTAssertEqual(source.framePosition, length)
        XCTAssertTrue(result.allSatisfy { $0.sampleRate == 24_000 && !$0.isFloat })
        return Fixture(pcm: result, sourceRate: source.processingFormat.sampleRate, sourceFrames: length)
    }

    private func checksum(_ pcm: [VoicePCMFrame]) throws -> String {
        let shape: [[String: Any]] = pcm.map {
            ["frames": $0.frames, "sample_rate": $0.sampleRate, "float": $0.isFloat,
             "bytes_sha256": SemanticRequestBudget.digest($0.bytes)]
        }
        return SemanticRequestBudget.digest(try JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys]))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func confirmedFixture() throws -> URL {
        let audio = projectRoot.appendingPathComponent(".agent/results/P3/audio")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: audio.appendingPathComponent("manifest.json"))) as? [String: Any])
        let recordings = try XCTUnwrap(manifest["recordings"] as? [[String: Any]])
        let fixture = try XCTUnwrap(recordings.last {
            $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true
        })
        let name = try XCTUnwrap(fixture["wav"] as? String)
        guard URL(fileURLWithPath: name).lastPathComponent == name else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return audio.appendingPathComponent(name)
    }

    @MainActor
    func testConfirmedFixtureConversion() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_P3_NATIVE_FIXTURE_CHECK"] == "1" else {
            throw XCTSkip("explicit private real-fixture conversion check required")
        }
        let fixture = try await frames(confirmedFixture())
        XCTAssertEqual(fixture.sourceFrames, Int64(fixture.sourceRate * 2.9006875))
        XCTAssertLessThanOrEqual(abs(Double(fixture.sourceFrames) / fixture.sourceRate - 2.9006875),
                                1 / fixture.sourceRate)
        XCTAssertNotEqual(try checksum(fixture.pcm), try checksum(Array(fixture.pcm.dropLast())))
        print("NATIVE_FIXTURE source_rate=\(fixture.sourceRate) source_frames=\(fixture.sourceFrames) "
              + "packets=\(fixture.pcm.count) samples24k=\(fixture.pcm.reduce(0) { $0 + $1.frames })")
    }

    private func write(_ value: [String: Any], to file: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try file.write(contentsOf: data + Data([10]))
    }

    @MainActor
    private func waitIdle(_ provider: LocalTranscriber) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !(await provider.partialDiagnostics.idle), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await provider.partialDiagnostics.idle else { throw LocalSpeechError.busy }
    }

    @MainActor
    func testProductionNativeTailReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_P3_NATIVE_TAIL"] == "1", env["JARVIS_P3_NATIVE_TAIL_READY"] == "1" else {
            throw XCTSkip("explicit native replay and quiet normal-app readiness required")
        }
        guard !IsSecureEventInputEnabled() else {
            throw XCTSkip("secure input is active; native stress workload was not started")
        }
        let runID = try XCTUnwrap(env["JARVIS_P3_NATIVE_TAIL_RUN_ID"])
        XCTAssertFalse(runID.isEmpty)
        guard !runID.isEmpty, runID.count <= 32,
              runID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = projectRoot
        let fixtureURL = try confirmedFixture()
        let prepared = try await frames(fixtureURL)
        let pcm = prepared.pcm
        let expectedPCMHash = try checksum(pcm)
        let duration = pcm.reduce(0.0) { $0 + Double($1.frames) / $1.sampleRate }
        let output = root.appendingPathComponent(".agent/results/P3/speech-evidence/native-tail-\(runID).jsonl")
        let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try write([
            "kind": "header", "schema_version": 1, "expected_trials": 90,
            "scope": "production_provider_file_replay_not_physical", "fixture_id": "h15",
            "fixture_sha256": SemanticRequestBudget.digest(try Data(contentsOf: fixtureURL)),
            "provider_sha256": SemanticRequestBudget.digest(try Data(contentsOf:
                root.appendingPathComponent("Sources/JevVoice/Intelligence/LocalTranscriber.swift"))),
            "test_sha256": SemanticRequestBudget.digest(try Data(contentsOf: URL(fileURLWithPath: #filePath))),
            "pcm_frames": pcm.count, "captured_seconds": duration,
            "source_sample_rate": prepared.sourceRate, "source_clip_frames": prepared.sourceFrames,
            "source_clip_seconds": Double(prepared.sourceFrames) / prepared.sourceRate,
            "converted_samples_24k": pcm.reduce(0) { $0 + $1.frames },
            "converted_frame_sizes": pcm.map(\.frames), "pcm_sha256": expectedPCMHash,
            "native_sample_goal_16k": 46411, "runtime": "swiftpm_release_test_module",
            "eou_probe_ms": 5, "max_owned_load_processes": 2,
            "backend_processing_time_available": false, "physical_input": false
        ], to: file)
        let partialGate = PartialGate()
        let provider = LocalTranscriber(beforePartialProcess: { await partialGate.wait() })
        let evidence = Evidence()
        var callbacks = 0
        let session = LocalSpeechSession(provider: provider) { _ in callbacks += 1 }
        session.context.entities = [.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true)]
        session.onDiagnostic = { evidence.append($0) }
        try await session.prewarm()
        let arms = ["clean", "eou-armed", "external-load"]
        var completed = 0
        var failures = 0
        var eouOverlapTrials = 0
        for iteration in 0..<30 {
            for offset in 0..<arms.count {
                let arm = arms[(iteration + offset) % arms.count]
                try await waitIdle(provider)
                await partialGate.setBlocked(arm != "eou-armed")
                let overlapped = try await trial(
                    arm: arm, iteration: iteration, pcm: pcm, pcmHash: expectedPCMHash, duration: duration,
                    provider: provider, session: session, gate: partialGate, evidence: evidence,
                    file: file, failures: &failures)
                if arm == "eou-armed", overlapped { eouOverlapTrials += 1 }
                completed += 1
            }
        }
        try write(["kind": "summary", "completed_trials": completed, "failed_trials": failures,
                   "admission_callbacks": callbacks, "eou_overlap_trials": eouOverlapTrials,
                   "eou_condition_coverage_complete": eouOverlapTrials == 30, "physical_input": false], to: file)
        print("NATIVE_TAIL completed=\(completed) failures=\(failures) eou_overlap=\(eouOverlapTrials)")
        XCTAssertEqual(completed, 90)
        XCTAssertEqual(failures, 0, "all failed attempts remain in the private journal")
        XCTAssertEqual(eouOverlapTrials, 30, "armed trials without sampled logical overlap remain coverage holes")
    }

    @MainActor
    private func trial(
        arm: String, iteration: Int, pcm: [VoicePCMFrame], pcmHash: String, duration: Double,
        provider: LocalTranscriber, session: LocalSpeechSession, gate: PartialGate,
        evidence: Evidence, file: FileHandle, failures: inout Int
    ) async throws -> Bool {
        let actualPCMHash = try checksum(pcm)
        guard actualPCMHash == pcmHash else { throw LocalSpeechError.captureLoss }
        var load: [Process] = []
        defer {
            for process in load {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
        }
        if arm == "external-load" {
            guard !IsSecureEventInputEnabled() else {
                try write(["kind": "abort", "reason": "secure_input", "arm": arm, "iteration": iteration], to: file)
                throw CancellationError()
            }
            guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else {
                try write(["kind": "abort", "reason": "thermal_state", "arm": arm, "iteration": iteration], to: file)
                throw LocalSpeechError.unavailable
            }
            for _ in 0..<min(2, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                load.append(process)
            }
        }
        let turn = try await session.beginCapture(id: UUID(), mode: .command,
            now: ProcessInfo.processInfo.systemUptime)
        for (index, frame) in pcm.enumerated() {
            try await session.consume(frame, sequence: index, turn: turn, retainRemote: false)
        }
        if arm == "eou-armed" {
            let until = ProcessInfo.processInfo.systemUptime + 0.5
            while await provider.partialDiagnostics.nativeActive == 0,
                  ProcessInfo.processInfo.systemUptime < until {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let activeAtRelease = await provider.partialDiagnostics.nativeActive
        let overlap = LockedBox(false)
        let loadInterrupted = LockedBox(false)
        let loadProcesses = load
        let probe = Task {
            while !Task.isCancelled {
                if !loadProcesses.isEmpty, IsSecureEventInputEnabled() {
                    loadInterrupted.set(true)
                    loadProcesses.filter(\.isRunning).forEach { $0.terminate() }
                }
                if evidence.has(turn.id, "provider.decode_begin"),
                   !evidence.has(turn.id, "provider.decode_settled"),
                   await provider.partialDiagnostics.nativeActive > 0 { overlap.set(true) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { probe.cancel() }
        let released = ProcessInfo.processInfo.systemUptime
        var accepted = false
        var errorCode = "none"
        do {
            let admission = try await session.finishCapture(turn, acceptedFrames: pcm.count,
                releasedAt: released, capturedSeconds: duration, drain: {})
            accepted = admission?.route == .local && admission?.slots["target_id"] == "com.apple.calculator"
        } catch {
            errorCode = (error as? LocalSpeechError).map { String(describing: $0) }
                ?? (error is CancellationError ? "cancelled" : "unknown")
        }
        let ended = ProcessInfo.processInfo.systemUptime
        await gate.setBlocked(false)
        let until = ProcessInfo.processInfo.systemUptime + 10
        while evidence.has(turn.id, "provider.decode_begin"),
              !evidence.has(turn.id, "provider.decode_settled"),
              ProcessInfo.processInfo.systemUptime < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = evidence.has(turn.id, "provider.decode_begin")
        let settled = evidence.has(turn.id, "provider.decode_settled")
        let diagnostics = evidence.events(turn.id)
        let nativeSamples = diagnostics.first { $0.stage == "provider.finish_enter" }?.metrics["samples"]
        let events: [[String: Any]] = diagnostics.map {
            ["stage": $0.stage, "monotonic": $0.monotonic, "metrics": $0.metrics]
        }
        try write([
            "kind": "trial", "arm": arm, "iteration": iteration, "turn": turn.id.uuidString,
            "pcm_sha256": actualPCMHash, "actual_native_samples_16k": nativeSamples.map { $0 as Any } ?? NSNull(),
            "admitted_expected_command": accepted, "error": errorCode,
            "release_final_ms": (ended - released) * 1000,
            "native_active_at_release": activeAtRelease,
            "logical_eou_call_overlap_sampled": overlap.value,
            "decode_started": started, "decode_settled_before_next_trial": settled,
            "native_coverage_complete": started && settled,
            "owned_load_processes": load.count,
            "load_interrupted_for_secure_input": loadInterrupted.value,
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue, "events": events
        ], to: file)
        if !accepted { failures += 1 }
        guard started && settled else { throw LocalSpeechError.busy }
        guard !loadInterrupted.value else { throw CancellationError() }
        return overlap.value
    }
}

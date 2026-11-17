import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import JevVoice

@MainActor
final class VoiceTurnEvidenceTests: XCTestCase {
    private final class Capture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var onReadiness: ((SpeechReadiness) -> Void)?
        var id: UUID?
        func prepare(inputUID: String?) async throws -> String { "fixture" }
        func suspend() async {}
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
            id = session; return "fixture"
        }
        func finish() {}
        func cancel() {}
    }

    private struct Keys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func fixture(_ evidence: VoiceTurnEvidence) -> (VoiceController, Capture) {
        let config = Config(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                            keyStore: Keys(), openAIKeyStore: Keys(), environment: [:])
        let capture = Capture()
        let coordinator = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
        return (VoiceController(config: config, speech: capture, authorize: { true },
                                cuaRuntime: coordinator, turnEvidence: evidence), capture)
    }

    private func begin(_ controller: VoiceController, _ capture: Capture) async throws -> UUID {
        controller.begin()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while capture.id == nil, ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
        }
        return try XCTUnwrap(capture.id)
    }

    func testControllerRecordsPartialFailureThenUserCancelBeforeAdmission() async throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let (controller, capture) = fixture(evidence)
        let id = try await begin(controller, capture)
        capture.onEvent?(id, .partial("open Calculator"))
        controller.finish()
        capture.onEvent?(id, .failure(LocalSpeechError.deadline.localizedDescription))
        XCTAssertEqual(controller.status, .reviewTranscript)
        controller.cancelCaptureAttempt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.fileURL.path),
                      "A failed recognition turn must not disappear before admission.")
        if FileManager.default.fileExists(atPath: evidence.fileURL.path) {
            let row = try XCTUnwrap(rows(evidence.fileURL).first)
            XCTAssertEqual(row["turn"] as? String, id.uuidString)
            XCTAssertEqual(row["final_text"] as? String, "")
            XCTAssertEqual(row["last_partial"] as? String, "open Calculator")
            XCTAssertEqual(row["failure_code"] as? String, "deadline")
            XCTAssertEqual(row["terminal"] as? String, "cancelled")
            XCTAssertEqual(row["dispatches"] as? Int, 0)
        }
        await controller.shutdown()
    }

    func testControllerRecordsFatalFailureWithoutAdmission() async throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let (controller, capture) = fixture(evidence)
        let id = try await begin(controller, capture)
        controller.finish()
        capture.onEvent?(id, .failure(LocalSpeechError.deadline.localizedDescription))
        let row = try XCTUnwrap(rows(evidence.fileURL).first)
        XCTAssertEqual(row["terminal"] as? String, "failed")
        XCTAssertEqual(row["failure_code"] as? String, "deadline")
        XCTAssertEqual(row["route"] as? String, "none")
        XCTAssertEqual(row["works_created"] as? Int, 0)
        await controller.shutdown()
    }

    func testOlderSettledWorkClosesWhileNewCaptureStaysPending() async throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let previous = UUID()
        evidence.open(turn: previous, input: "voice", beganAt: 1)
        let (controller, capture) = fixture(evidence)
        let current = try await begin(controller, capture)
        let older = work(application: "com.apple.calculator", outcome: .done, captureID: previous)
        controller.maybeFlushEvidence(works: [older])
        XCTAssertFalse(evidence.isPending(previous))
        XCTAssertTrue(evidence.isPending(current))
        if FileManager.default.fileExists(atPath: evidence.fileURL.path) {
            let row = try XCTUnwrap(rows(evidence.fileURL).first)
            XCTAssertEqual(row["turn"] as? String, previous.uuidString)
            XCTAssertEqual(row["terminal"] as? String, "settled")
        } else {
            XCTFail("Older completed work must not wait for the grace timer.")
        }
        await controller.shutdown()
    }

    func testOlderActiveWorkDoesNotCloseFromUnrelatedChange() async throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let previous = UUID()
        evidence.open(turn: previous, input: "voice", beganAt: 1)
        let (controller, capture) = fixture(evidence)
        let current = try await begin(controller, capture)
        controller.maybeFlushEvidence(works: [
            work(application: "com.apple.calculator", outcome: nil, active: true, captureID: previous)
        ])
        XCTAssertTrue(evidence.isPending(previous))
        XCTAssertTrue(evidence.isPending(current))
        await controller.shutdown()
    }

    func testAdmissionAmendsCaptureAndLateEventsRemainAfterSingleTerminal() throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let turn = UUID()
        evidence.open(turn: turn, input: "voice", beganAt: 10)
        evidence.partial(turn: turn, text: "open cal")
        evidence.release(turn: turn, at: 12)
        evidence.begin(turn: turn, heard: "open Calculator", input: "voice", submittedAt: 13, releasedAt: 12)
        evidence.flush(turn: turn, terminal: "done", status: "Done", uptime: 14, trace: [], works: [])
        evidence.begin(turn: turn, heard: "wrong late result", input: "voice", submittedAt: 15, releasedAt: 0)
        evidence.event(turn: turn, name: "decode_settled", at: 16, metrics: ["cancelled": 1])
        evidence.flush(turn: turn, terminal: "failed", status: "Error", uptime: 17, trace: [], works: [])
        let all = try rows(evidence.fileURL)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0]["began_uptime"] as? Double, 10)
        XCTAssertEqual(all[0]["released_uptime"] as? Double, 12)
        XCTAssertEqual(all[0]["last_partial"] as? String, "open cal")
        XCTAssertEqual(all[0]["final_text"] as? String, "open Calculator")
        XCTAssertTrue(try rows(evidence.journalURL).contains { $0["stage"] as? String == "decode_settled" })
    }

    func testDictationRedactionIncludesConvertedPartialsAndJournal() throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let turn = UUID()
        evidence.open(turn: turn, input: "voice", beganAt: 10)
        evidence.partial(turn: turn, text: "private fixture words")
        evidence.setInput(turn: turn, input: "dictation")
        evidence.final(turn: turn, text: "private fixture words")
        evidence.flush(turn: turn, terminal: "done", status: "Done", uptime: 11, trace: [], works: [])
        for file in [evidence.fileURL, evidence.journalURL] {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("private fixture words"))
        }
        XCTAssertEqual(try rows(evidence.fileURL).first?["content_redacted"] as? Bool, true)
    }

    func testWriterHealthFailureAndPrivateFiles() throws {
        let root = tempDir(), bad = root.appendingPathComponent("not-directory")
        try Data().write(to: bad)
        let broken = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": bad.path]))
        XCTAssertFalse(broken.writable)
        XCTAssertNotNil(broken.lastError)
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": root.path]))
        XCTAssertTrue(evidence.writable)
        XCTAssertEqual(try rows(evidence.journalURL).first?["kind"] as? String, "self_check")
        let health = try JSONSerialization.jsonObject(with: Data(contentsOf: evidence.healthURL)) as? [String: Any]
        XCTAssertEqual(health?["writable"] as? Bool, true)
        let mode = try FileManager.default.attributesOfItem(atPath: evidence.journalURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let turn = UUID()
        evidence.open(turn: turn, input: "voice", beganAt: 10)
        try FileManager.default.removeItem(at: evidence.journalURL)
        try FileManager.default.createDirectory(at: evidence.journalURL, withIntermediateDirectories: false)
        evidence.event(turn: turn, name: "forced_write_failure")
        XCTAssertFalse(evidence.writable)
        XCTAssertEqual(evidence.lastError, "writer_append_failed")
    }

    func testGraceProducesIncompleteCollectionNotEffectLatency() async throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(
            environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path], graceSeconds: 0.001))
        let turn = UUID(), flushed = expectation(description: "grace")
        evidence.onGrace = { id in
            evidence.flush(turn: id, terminal: "grace_timeout", status: "not_current", uptime: 15,
                           trace: [], works: [])
            flushed.fulfill()
        }
        evidence.open(turn: turn, input: "voice", beganAt: 10)
        await fulfillment(of: [flushed], timeout: 1)
        let row = try XCTUnwrap(rows(evidence.fileURL).first)
        XCTAssertNil(row["settle_ms"])
        XCTAssertNil(row["dispatch_ms"])
        XCTAssertEqual(row["collection_ms"] as? Double, 5000)
    }

    func testFailedTerminalWriteRetainsPendingTurnAndBlocksSession() throws {
        let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
        let turn = UUID()
        evidence.open(turn: turn, input: "voice", beganAt: 10)
        try FileManager.default.createDirectory(at: evidence.fileURL, withIntermediateDirectories: false)
        evidence.flush(turn: turn, terminal: "failed", status: "Error", uptime: 11, trace: [], works: [])
        XCTAssertTrue(evidence.isPending(turn), "Failed disk delivery must not discard the only terminal state.")
        XCTAssertFalse(evidence.writable)
        XCTAssertEqual(evidence.lastError, "writer_append_failed")
    }

    func testFailureClassesDoNotStorePrivateErrorBodies() throws {
        let cases = [
            ("Microphone configuration changed.", "microphone_interrupted"),
            ("The voice connection dropped. Release Fn to retry.", "sender_failed"),
            ("The voice session closed.", "socket_closed"),
            ("The voice server stopped responding. Press Fn to reconnect.", "socket_watchdog"),
            ("No response arrived. Hold Fn and try again.", "controller_watchdog"),
            ("The Fn release was missed. Hold Fn again to retry.", "fn_release_missed"),
            ("Keyboard monitoring was interrupted. Hold Fn again to retry.", "input_interrupted"),
            ("Secure keyboard input interrupted recording.", "secure_input")
        ]
        for (message, expected) in cases {
            let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
            let turn = UUID()
            evidence.open(turn: turn, input: "voice", beganAt: 10)
            evidence.failure(turn: turn, message: message + " fixture-private-token")
            evidence.flush(turn: turn, terminal: "failed", status: "Error", uptime: 11, trace: [], works: [])
            XCTAssertEqual(try rows(evidence.fileURL).first?["failure_code"] as? String, expected)
            for file in [evidence.fileURL, evidence.journalURL] {
                XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("fixture-private-token"))
            }
        }
    }

    func testProductionFinalizationDiagnosticsKeepTurnAndDeadlineReason() async throws {
        for expired in [false, true] {
            let events = LockedBox<[VoiceSpeechDiagnostic]>([])
            let session = LocalSpeechSession(provider: LocalSpeechTests.SlowProvider(delay: 0)) { _ in }
            session.onDiagnostic = { event in
                Task { @MainActor in events.set(events.value + [event]) }
            }
            let turn = try await session.beginCapture(id: UUID(), mode: .command,
                                                     now: ProcessInfo.processInfo.systemUptime - 4)
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: 24_000, channels: 1, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            buffer.int16ChannelData?[0].initialize(repeating: 0, count: 480)
            try await session.consume(VoicePCMFrame(copying: buffer), sequence: 0, turn: turn)
            let released = ProcessInfo.processInfo.systemUptime - (expired ? 3 : 0)
            do {
                _ = try await session.finishCapture(turn, acceptedFrames: 1, releasedAt: released,
                                                    capturedSeconds: 0.02, drain: {})
                XCTAssertFalse(expired)
            } catch {
                XCTAssertTrue(expired)
                XCTAssertEqual(error as? LocalSpeechError, .deadline)
            }
            let stage = expired ? "finalization.failure.deadline" : "finalization.admitted"
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while !events.value.contains(where: { $0.stage == stage }),
                  ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
            XCTAssertTrue(events.value.contains { $0.stage == stage })
            XCTAssertTrue(events.value.allSatisfy { $0.turn == turn.id })
            XCTAssertEqual(events.value.first?.metrics["budget_ms"], 2000)
        }
    }

    func testControllerRecordsCancellationAndEmptyFinalWithoutAdmission() async throws {
        for empty in [false, true] {
            let evidence = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": tempDir().path]))
            let (controller, capture) = fixture(evidence)
            let id = try await begin(controller, capture)
            controller.finish()
            if empty { capture.onEvent?(id, .final("")) } else { controller.cancelCaptureAttempt() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.fileURL.path))
            if FileManager.default.fileExists(atPath: evidence.fileURL.path) {
                let row = try XCTUnwrap(rows(evidence.fileURL).first)
                XCTAssertEqual(row["terminal"] as? String, empty ? "no_speech" : "cancelled")
                XCTAssertEqual(row["status"] as? String, controller.status.title)
                XCTAssertEqual(row["works_created"] as? Int, 0)
            }
            await controller.shutdown()
        }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func rows(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    private func work(application: String? = nil, outcome: VoiceTaskCoordinator.Work.Outcome?,
                      active: Bool = false, captureID: UUID? = nil) -> VoiceTaskCoordinator.Work {
        let w = VoiceTaskCoordinator.Work(label: "t", request: "req",
                                          spec: DriveTask(goal: "g", application: application))
        w.outcome = outcome; w.active = active; w.captureID = captureID
        return w
    }

    func testRecorderIsNilWithoutEnv() {
        XCTAssertNil(VoiceTurnEvidence(environment: [:]))
        XCTAssertNil(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": ""]))
    }

    func testLocalTurnRowCapturesRouteDispatchOutcomeAndLatencies() throws {
        let dir = tempDir(), turn = UUID()
        let evidence = try XCTUnwrap(
            VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": dir.path]))
        let trace = VoiceCommandTrace()
        trace.record(.admissionLocal, turn: turn)
        trace.record(.executorBegin, turn: turn)
        trace.record(.driverBegin, turn: turn, tool: .foreground)
        trace.record(.driverEnd, turn: turn, tool: .foreground)
        trace.record(.executorEnd, turn: turn)
        let executorAt = trace.events.first { $0.stage == .executorBegin }!.monotonic
        let done = work(application: "com.apple.calculator", outcome: .done, captureID: turn)
        evidence.begin(turn: turn, heard: "open Calculator", input: "voice",
                       submittedAt: executorAt - 0.2, releasedAt: executorAt - 0.3)
        evidence.flush(turn: turn, terminal: "settled", status: "Done",
                       uptime: executorAt + 1.0,
                       trace: trace.events.filter { $0.turn == turn }, works: [done])
        let row = try XCTUnwrap(rows(evidence.fileURL).first)
        XCTAssertEqual(row["schema_version"] as? Int, 2)
        XCTAssertEqual(row["input"] as? String, "voice")
        XCTAssertEqual(row["heard"] as? String, "open Calculator")
        XCTAssertEqual(row["heard_sha256"] as? String,
                       SHA256.hash(data: Data("open Calculator".utf8))
                           .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(row["route"] as? String, "local")
        XCTAssertEqual(row["terminal"] as? String, "settled")
        XCTAssertEqual(row["works_created"] as? Int, 1)
        XCTAssertEqual(row["dispatches"] as? Int, 1)
        XCTAssertEqual(row["tools"] as? [String], ["foreground"])
        XCTAssertEqual((row["dispatch_ms"] as? Double).map { round($0) }, 300)
        XCTAssertEqual((row["settle_ms"] as? Double).map { round($0) }, 1300)
        let workRow = try XCTUnwrap((row["works"] as? [[String: Any]])?.first)
        XCTAssertEqual(workRow["application"] as? String, "com.apple.calculator")
        XCTAssertEqual(workRow["outcome"] as? String, "done")
        XCTAssertTrue(workRow["window_id"] is NSNull)
    }

    func testRouteDerivationAndIdempotentFlush() throws {
        let dir = tempDir()
        let evidence = try XCTUnwrap(
            VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": dir.path]))
        let clarify = UUID(), refuse = UUID(), dictation = UUID(), silent = UUID()
        let trace = VoiceCommandTrace()
        trace.record(.admissionClarify, turn: clarify)
        trace.record(.admissionRefuse, turn: refuse)
        evidence.begin(turn: clarify, heard: "open it", input: "voice",
                       submittedAt: 0, releasedAt: 0)
        evidence.begin(turn: refuse, heard: "format my disk", input: "voice",
                       submittedAt: 0, releasedAt: 0)
        evidence.begin(turn: dictation, heard: "hello there", input: "dictation",
                       submittedAt: 0, releasedAt: 0)
        evidence.begin(turn: silent, heard: "open Calculator", input: "voice",
                       submittedAt: 0, releasedAt: 0)
        for (turn, terminal) in [(clarify, "awaiting_user"), (refuse, "done"),
                                 (dictation, "done"), (silent, "grace_timeout")] {
            evidence.flush(turn: turn, terminal: terminal, status: "Idle", uptime: 1,
                           trace: trace.events.filter { $0.turn == turn }, works: [])
        }
        evidence.flush(turn: clarify, terminal: "settled", status: "Idle", uptime: 2,
                       trace: [], works: [work(outcome: .done)])
        let all = try rows(evidence.fileURL)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.map { $0["route"] as? String },
                       ["clarify", "refuse", "dictation", "none"])
        XCTAssertEqual(all.map { $0["works_created"] as? Int }, [0, 0, 0, 0])
    }
}

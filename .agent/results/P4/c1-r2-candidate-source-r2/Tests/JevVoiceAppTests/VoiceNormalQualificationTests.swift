import Darwin
import Foundation
import XCTest
@testable import JevVoice

@MainActor
final class VoiceNormalQualificationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func authorization(_ root: URL, maximum: Int = 5, corpus: String? = nil,
                               expires: Double = Date().timeIntervalSince1970 + 3600) throws {
        let auth = SemanticRequestBudget.Authorization(id: "normal-voice-unit", scope: "typesafe-text-only",
            maximumRequests: maximum, corpusSHA256: corpus ?? VoiceNormalQualification.corpusSHA256,
            expiresAt: expires)
        try JSONEncoder().encode(auth).write(to: root.appendingPathComponent("authorization.json"))
    }

    private func environment(_ root: URL, mode: String = "physical") -> [String: String] {
        ["JARVIS_P3_NORMAL_QUALIFICATION": mode, "JARVIS_P3_NORMAL_DIRECTORY": root.path,
         "JARVIS_VOICE_EVIDENCE_DIR": root.path]
    }

    func testOrdinaryLaunchHasNoQualificationOrNetworkPolicyChange() throws {
        XCTAssertNil(try VoiceNormalQualification.profile(environment: [:], arguments: ["JevVoice"]))
    }

    nonisolated func testFreshForegroundPersistsWhileWindowInventoryIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DispatchGroup()
        gate.enter()
        let entered = DispatchSemaphore(value: 0)
        let observer = try await MainActor.run {
            let recorder = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": root.path]))
            let observer = try VoiceNormalQualification(
                configuration: .init(directory: root, mode: .physical, budget: nil),
                executableSHA256: String(repeating: "a", count: 64), lane: "RealtimeVoiceLane",
                windowProbe: {
                    let began = ProcessInfo.processInfo.systemUptime
                    entered.signal()
                    gate.wait()
                    return ["monotonic": ProcessInfo.processInfo.systemUptime,
                            "window_query_began": began, "window_probe_complete": true,
                            "frontmost_pid": 20, "frontmost_app": "com.apple.calculator",
                            "visible_windows": [["pid": 20, "window_id": 71, "width": 400, "height": 500]]]
                },
                foregroundProbe: {
                    ["monotonic": ProcessInfo.processInfo.systemUptime,
                     "frontmost_pid": 20, "frontmost_app": "com.apple.calculator"]
                })
            observer.attach(to: recorder)
            recorder.open(turn: UUID(), input: "voice", beganAt: ProcessInfo.processInfo.systemUptime)
            return observer
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let file = root.appendingPathComponent("witness.jsonl")
        func rows() -> [[String: Any]] {
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while rows().filter({ $0["kind"] as? String == "foreground" }).count < 3,
              ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let blockedRows = rows()
        XCTAssertGreaterThanOrEqual(blockedRows.filter { $0["kind"] as? String == "foreground" }.count, 3)
        XCTAssertFalse(blockedRows.contains { $0["kind"] as? String == "window" })
        XCTAssertEqual(entered.wait(timeout: .now()), .timedOut, "Only one window query may be in flight")
        let releasedAt = ProcessInfo.processInfo.systemUptime
        gate.leave()
        await observer.stop()
        let completedRows = rows()
        let windows = completedRows.filter { $0["kind"] as? String == "window" }
        XCTAssertFalse(windows.isEmpty, "Stop must drain the accepted in-flight window query")
        XCTAssertTrue(windows.allSatisfy { ($0["monotonic"] as? Double ?? 0) >= releasedAt })
        XCTAssertEqual(completedRows.last?["kind"] as? String, "stopped")
        let health = try JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("witness-health.json"))) as? [String: Any]
        XCTAssertEqual(health?["rows"] as? Int, completedRows.count)
        XCTAssertEqual(health?["writable"] as? Bool, true)
    }

    nonisolated func testMalformedWindowProbeFailsWithoutPersistingWindowProof() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let observer = try await MainActor.run {
            let recorder = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": root.path]))
            let observer = try VoiceNormalQualification(
                configuration: .init(directory: root, mode: .physical, budget: nil),
                executableSHA256: String(repeating: "a", count: 64), lane: "RealtimeVoiceLane",
                windowProbe: { ["monotonic": ProcessInfo.processInfo.systemUptime] },
                foregroundProbe: {
                    ["monotonic": ProcessInfo.processInfo.systemUptime,
                     "frontmost_pid": 20, "frontmost_app": "com.apple.calculator"]
                })
            observer.attach(to: recorder)
            recorder.open(turn: UUID(), input: "voice", beganAt: ProcessInfo.processInfo.systemUptime)
            return observer
        }
        let healthFile = root.appendingPathComponent("witness-health.json")
        func failure() -> String? {
            guard let data = try? Data(contentsOf: healthFile),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return row["failure"] as? String
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while failure() == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await observer.stop()
        XCTAssertEqual(failure(), "invalid_window_observation")
        let text = try String(contentsOf: root.appendingPathComponent("witness.jsonl"), encoding: .utf8)
        let windows = text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["kind"] as? String == "window" }
        XCTAssertTrue(windows.isEmpty)
    }

    nonisolated func testWitnessPersistsWhileMainActorCannotDrainCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("witness.jsonl")
        let result = root.appendingPathComponent("progress")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            guard entered.wait(timeout: .now() + 5) == .success else { release.signal(); return }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var progressed = false, sharedSnapshot = false
            repeat {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let rows = text.split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.filter { $0["kind"] as? String == "window" }
                progressed = !rows.isEmpty
                let times = Dictionary(grouping: rows, by: { $0["monotonic"] as? Double ?? -1 })
                sharedSnapshot = times.values.contains { Set($0.compactMap { $0["turn"] as? String }).count == 3 }
                if progressed && sharedSnapshot { break }
                Thread.sleep(forTimeInterval: 0.01)
            } while ProcessInfo.processInfo.systemUptime < deadline
            try? Data([progressed ? 1 : 0, sharedSnapshot ? 1 : 0]).write(to: result)
            release.signal()
        }
        try await MainActor.run {
            let recorder = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": root.path]))
            let observer = try VoiceNormalQualification(
                configuration: .init(directory: root, mode: .typedObserver, budget: nil),
                executableSHA256: String(repeating: "a", count: 64), lane: "RealtimeVoiceLane")
            observer.attach(to: recorder)
            for _ in 0..<3 {
                recorder.open(turn: UUID(), input: "typed", beganAt: ProcessInfo.processInfo.systemUptime)
            }
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            observer.stop()
        }
        XCTAssertEqual(try Data(contentsOf: result), Data([1, 1]),
                       "Independent evidence must persist and fan out one snapshot without the UI actor")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let health = try JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("witness-health.json"))) as? [String: Any]
        XCTAssertEqual(health?["rows"] as? Int, lines.count)
        XCTAssertTrue(lines.last?.contains("\"kind\":\"stopped\"") == true)
    }

    func testWitnessWriterStopDrainsEveryAcceptedRow() throws {
        let root = try directory()
        let writer = try VoiceNormalWitnessWriter(directory: root, mode: "typed-observer")
        for index in 0..<100 {
            writer.append(Data("{\"index\":\(index)}".utf8))
        }
        writer.stop()
        let rows = try String(contentsOf: root.appendingPathComponent("witness.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Int] }
        XCTAssertEqual(rows.compactMap { $0?["index"] }, Array(0..<100))
        let health = try JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("witness-health.json"))) as? [String: Any]
        XCTAssertEqual(health?["rows"] as? Int, 100)
        XCTAssertEqual(health?["writable"] as? Bool, true)
    }

    func testPersistentWitnessDescriptorClosesOnExec() throws {
        let root = try directory()
        let writer = try VoiceNormalWitnessWriter(directory: root, mode: "typed-observer")
        defer { writer.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("witness.jsonl").path)
        let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
        var found = false
        for fd in 0..<getdtablesize() {
            var info = stat()
            if fstat(fd, &info) == 0, UInt64(info.st_ino) == inode {
                found = true
                XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
            }
        }
        XCTAssertTrue(found)
    }

    func testWitnessWriterCapacityFailureDoesNotLosePreviouslyAcceptedRows() throws {
        let root = try directory(), queue = DispatchQueue(label: "witness-capacity-test")
        let writer = try VoiceNormalWitnessWriter(directory: root, mode: "typed-observer", queue: queue)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for index in 0..<129 {
            writer.append(Data("{\"index\":\(index)}".utf8))
        }
        release.signal()
        writer.stop()
        let lines = try String(contentsOf: root.appendingPathComponent("witness.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let health = try JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("witness-health.json"))) as? [String: Any]
        XCTAssertEqual(lines.count, 128)
        XCTAssertEqual(health?["rows"] as? Int, 128)
        XCTAssertEqual(health?["writable"] as? Bool, false)
        XCTAssertEqual(health?["failure"] as? String, "writer_backpressure")
    }

    func testPartialOrUnknownOptInCannotBecomeAnUncappedNormalLaunch() throws {
        let root = try directory()
        try authorization(root)
        XCTAssertThrowsError(try VoiceNormalQualification.profile(
            environment: environment(root), arguments: ["JevVoice"]))
        XCTAssertThrowsError(try VoiceNormalQualification.profile(
            environment: [:], arguments: ["JevVoice", "--p3-normal-qualification"]))
        XCTAssertThrowsError(try VoiceNormalQualification.profile(
            environment: environment(root, mode: "anything"), arguments: ["JevVoice", "--p3-normal-qualification"]))
    }

    func testPhysicalProfileKeepsSemanticBudgetAndRejectsArbitraryRemoteReasoning() async throws {
        let root = try directory()
        try authorization(root)
        let profile = try XCTUnwrap(VoiceNormalQualification.profile(
            environment: environment(root), arguments: ["JevVoice", "--p3-normal-qualification"]))
        XCTAssertEqual(profile.mode, .physical)
        XCTAssertEqual(profile.directory.path, root.path)
        let authorization = await profile.budget?.authorization
        XCTAssertEqual(authorization?.maximumRequests, 5)
        XCTAssertFalse(profile.remoteReasoningPermitted)
    }

    func testExpiredWrongCorpusAndOverCapBudgetsFailBeforeCapture() throws {
        let root = try directory()
        let args = ["JevVoice", "--p3-normal-qualification"]
        try authorization(root, expires: 1)
        XCTAssertThrowsError(try VoiceNormalQualification.profile(environment: environment(root), arguments: args))
        try authorization(root, corpus: "wrong-corpus")
        XCTAssertThrowsError(try VoiceNormalQualification.profile(environment: environment(root), arguments: args))
        try authorization(root, maximum: 6)
        XCTAssertThrowsError(try VoiceNormalQualification.profile(environment: environment(root), arguments: args))
    }

    func testSharedDirectoryExistingWitnessAndMixedGUIOptInAreRejected() throws {
        let root = try directory()
        try authorization(root)
        let args = ["JevVoice", "--p3-normal-qualification"]
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try VoiceNormalQualification.profile(environment: environment(root), arguments: args))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var env = environment(root)
        env["JARVIS_P3_GUI_AUDIT"] = "1"
        XCTAssertThrowsError(try VoiceNormalQualification.profile(environment: env, arguments: args))
        try Data().write(to: root.appendingPathComponent("witness.jsonl"))
        XCTAssertThrowsError(try VoiceNormalQualification.profile(environment: environment(root), arguments: args))
    }

    func testPreviouslyReservedBudgetCannotStartAnotherPhysicalRun() throws {
        let root = try directory()
        try authorization(root)
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("requests.jsonl"))
        XCTAssertThrowsError(try VoiceNormalQualification.profile(
            environment: environment(root), arguments: ["JevVoice", "--p3-normal-qualification"]))
    }

    func testTypedObserverRemainsExplicitlyNonphysicalAndUsesExistingAuditBudget() throws {
        let root = try directory()
        var env = environment(root, mode: "typed-observer")
        env["JARVIS_P3_GUI_AUDIT"] = "1"
        env["JARVIS_P3_GUI_AUDIT_ROUTING_ONLY"] = "1"
        env["JARVIS_P3_GUI_AUDIT_RUN_ID"] = "unit-observer"
        let profile = try XCTUnwrap(VoiceNormalQualification.profile(
            environment: env, arguments: ["JevVoice", "--p3-user-audit"]))
        XCTAssertEqual(profile.mode, .typedObserver)
        XCTAssertNil(profile.budget)
        XCTAssertFalse(profile.remoteReasoningPermitted)
        XCTAssertThrowsError(try VoiceNormalQualification.profile(
            environment: env, arguments: ["JevVoice", "--p3-normal-qualification"]))
    }

    func testMutationMarksExcludeReadsAndWorkCreationButIncludeNativeActivation() {
        XCTAssertTrue(VoiceNormalQualification.isMutation(stage: "command.nativeUnhideBegin", tool: nil))
        XCTAssertTrue(VoiceNormalQualification.isMutation(stage: "command.nativeActivationBegin", tool: nil))
        XCTAssertTrue(VoiceNormalQualification.isMutation(stage: "command.driverBegin", tool: "foreground"))
        XCTAssertTrue(VoiceNormalQualification.isMutation(stage: "command.driverBegin", tool: "launchApp"))
        XCTAssertFalse(VoiceNormalQualification.isMutation(stage: "command.driverBegin", tool: "listWindows"))
        XCTAssertFalse(VoiceNormalQualification.isMutation(stage: "command.workCreated", tool: nil))
        XCTAssertFalse(VoiceNormalQualification.isMutation(stage: "command.nativeForegroundVerified", tool: nil))
        XCTAssertFalse(VoiceNormalQualification.isMutation(stage: "command.nativeUnhideEnd", tool: nil))
    }

    func testRecorderObserversPreserveLocalClarificationAndPersistedNativeMarks() throws {
        let root = try directory()
        let recorder = try XCTUnwrap(VoiceTurnEvidence(environment: ["JARVIS_VOICE_EVIDENCE_DIR": root.path]))
        var events: [[String: Any]] = []
        var terminals: [[String: Any]] = []
        recorder.onJournal = { events.append($0) }
        recorder.onTerminal = { terminals.append($0) }
        let turn = UUID(), task = UUID()
        recorder.open(turn: turn, input: "voice", beganAt: 1)
        recorder.release(turn: turn, at: 2)
        recorder.begin(turn: turn, heard: "Open calculation.", input: "voice", submittedAt: 2.1, releasedAt: 2)
        recorder.event(turn: turn, name: "semantic.proposal", at: 2.2)
        recorder.event(turn: turn, name: "command.nativeActivationBegin", at: 2.3, task: task)
        recorder.flush(turn: turn, terminal: "settled", status: "Done", uptime: 3,
            trace: [.init(turn: turn, task: nil, stage: .admissionClarify, tool: nil, monotonic: 2.1),
                    .init(turn: turn, task: task, stage: .nativeActivationBegin, tool: nil, monotonic: 2.3)],
            works: [])
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?["route"] as? String, "clarify")
        XCTAssertEqual(terminals.first?["heard"] as? String, "Open calculation.")
        XCTAssertTrue(events.contains { $0["stage"] as? String == "semantic.proposal" })
        XCTAssertTrue(events.contains { $0["stage"] as? String == "command.nativeActivationBegin" })
        let persisted = try String(contentsOf: recorder.journalURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("semantic.proposal"))
        XCTAssertTrue(persisted.contains("nativeActivationBegin"))
    }
}

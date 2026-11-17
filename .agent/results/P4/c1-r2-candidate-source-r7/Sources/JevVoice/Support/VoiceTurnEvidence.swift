import CryptoKit
import Foundation

@MainActor
final class VoiceTurnEvidence {
    private struct Pending {
        var heard = ""
        var hasFinal = false
        var finalHash = ""
        var finalWords = 0
        var input: String
        let beganAt: Double
        var submittedAt: Double = 0
        var releasedAt: Double = 0
        var lastPartial = ""
        var partials: [[String: Any]] = []
        var metrics: [String: Double] = [:]
        var failureCode: String?
        var failureHash: String?
        var dropped = 0
        var grace: Task<Void, Never>?
    }

    private let file: URL
    let journalURL: URL
    let healthURL: URL
    private let graceSeconds: Double
    private let executableHash: String
    private var pending: [UUID: Pending] = [:]
    private var finished: Set<UUID> = []
    private var eventCounts: [UUID: Int] = [:]
    private(set) var lastError: String?
    var writable: Bool { lastError == nil }
    var onGrace: ((UUID) -> Void)?
    var onJournal: (([String: Any]) -> Void)?
    var onTerminal: (([String: Any]) -> Void)?
    var executableSHA256: String { executableHash }

    init?(environment: [String: String] = ProcessInfo.processInfo.environment,
          graceSeconds: Double = 180) {
        guard let dir = environment["JARVIS_VOICE_EVIDENCE_DIR"], !dir.isEmpty else { return nil }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let identifier = UUID().uuidString
        file = root.appendingPathComponent("turns-\(identifier).jsonl")
        journalURL = root.appendingPathComponent("events-\(identifier).jsonl")
        healthURL = root.appendingPathComponent("health-\(identifier).json")
        self.graceSeconds = graceSeconds.isFinite ? min(300, max(0.001, graceSeconds)) : 180
        if let executable = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])) {
            executableHash = SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined()
        } else { executableHash = ""; lastError = "artifact_hash_unavailable" }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
                lastError = "directory_not_private"; writeHealth(); return
            }
            append(["kind": "self_check", "schema_version": 2], to: journalURL)
            guard try String(contentsOf: journalURL, encoding: .utf8).contains("self_check") else {
                lastError = "self_check_failed"; writeHealth(); return
            }
        } catch { lastError = "writer_initialization_failed" }
        writeHealth()
    }

    var fileURL: URL { file }

    @discardableResult
    private func append(_ row: [String: Any], to url: URL) -> Bool {
        guard lastError == nil else { return false }
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0a)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            lastError = "writer_append_failed"; writeHealth(); return false
        }
    }

    private func writeHealth() {
        let row: [String: Any] = ["schema_version": 2, "writable": writable,
                                 "executable_sha256": executableHash,
                                 "error": lastError ?? NSNull(), "pid": ProcessInfo.processInfo.processIdentifier,
                                 "turns_file": file.lastPathComponent, "events_file": journalURL.lastPathComponent]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: healthURL.path) {
            FileManager.default.createFile(atPath: healthURL.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: healthURL)
    }

    func open(turn: UUID, input: String, beganAt: Double) {
        guard pending[turn] == nil, !finished.contains(turn) else { return }
        guard pending.count < 64, finished.count < 2048 else {
            lastError = "session_capacity_exceeded"; writeHealth(); return
        }
        var row = Pending(input: input, beganAt: beganAt)
        row.grace = Task { @MainActor [weak self, graceSeconds] in
            do { try await Task.sleep(nanoseconds: UInt64(graceSeconds * 1e9)) } catch { return }
            self?.onGrace?(turn)
        }
        pending[turn] = row
        event(turn: turn, name: "opened", at: beganAt)
    }

    func begin(turn: UUID, heard: String, input: String,
               submittedAt: Double, releasedAt: Double) {
        open(turn: turn, input: input, beganAt: releasedAt > 0 ? releasedAt : submittedAt)
        guard pending[turn] != nil else { return }
        pending[turn]?.input = input
        pending[turn]?.submittedAt = submittedAt
        if releasedAt > 0 { pending[turn]?.releasedAt = releasedAt }
        final(turn: turn, text: heard)
        event(turn: turn, name: "admitted", at: submittedAt)
    }

    func event(turn: UUID, name: String, at: Double = ProcessInfo.processInfo.systemUptime,
               metrics: [String: Double] = [:], tool: VoiceCommandTrace.Tool? = nil, task: UUID? = nil) {
        guard pending[turn] != nil || finished.contains(turn) else { return }
        guard eventCounts[turn, default: 0] < 512 else {
            lastError = "journal_capacity_exceeded"; writeHealth(); return
        }
        eventCounts[turn, default: 0] += 1
        let safeMetrics = metrics.filter { $0.value.isFinite && abs($0.value) < 1e12 }
        var entry: [String: Any] = ["kind": "event", "turn": turn.uuidString, "stage": name,
                                    "monotonic": at, "metrics": safeMetrics]
        if let tool { entry["tool"] = tool.rawValue }
        if let task { entry["task"] = task.uuidString }
        guard append(entry, to: journalURL) else { return }
        onJournal?(entry)
        for (key, value) in safeMetrics { pending[turn]?.metrics["\(name).\(key)"] = value }
    }

    func release(turn: UUID, at: Double) {
        guard pending[turn] != nil, pending[turn]?.releasedAt == 0 else { return }
        pending[turn]?.releasedAt = at
        event(turn: turn, name: "released", at: at)
    }

    func setInput(turn: UUID, input: String) { pending[turn]?.input = input }

    func partial(turn: UUID, text: String) {
        guard var row = pending[turn] else { return }
        row.lastPartial = String(text.prefix(4096))
        row.metrics["text_dropped_characters", default: 0] += Double(max(0, text.count - 4096))
        if row.partials.count >= 32 { row.partials.removeFirst(); row.dropped += 1 }
        row.partials.append(["text": row.lastPartial, "monotonic": ProcessInfo.processInfo.systemUptime])
        pending[turn] = row
        event(turn: turn, name: "partial", metrics: ["characters": Double(text.count)])
    }

    func final(turn: UUID, text: String) {
        pending[turn]?.heard = String(text.prefix(4096))
        pending[turn]?.hasFinal = true
        pending[turn]?.finalHash = Self.digest(text)
        pending[turn]?.finalWords = text.split(whereSeparator: \.isWhitespace).count
        pending[turn]?.metrics["text_dropped_characters", default: 0] += Double(max(0, text.count - 4096))
        event(turn: turn, name: "final", metrics: ["characters": Double(text.count)])
    }

    func failure(turn: UUID, message: String) {
        guard pending[turn]?.failureCode == nil else { return }
        let lower = message.lowercased()
        let known = [
            ("the fn release was missed", "fn_release_missed"),
            ("keyboard monitoring was interrupted", "input_interrupted"),
            ("secure keyboard input interrupted", "secure_input"),
            ("microphone configuration changed", "microphone_interrupted"),
            ("microphone access is needed", "microphone_permission"),
            ("voice connection dropped", "sender_failed"),
            ("voice session closed", "socket_closed"),
            ("voice server stopped responding", "socket_watchdog"),
            ("no response arrived", "controller_watchdog"),
            ("no speech was captured", "no_speech"),
            ("no usable speech remains", "no_speech")
        ].first { lower.contains($0.0) }?.1
        let code = [LocalSpeechError.unavailable, .busy, .stale, .captureLoss, .tooShort, .emptyFinal, .deadline]
            .first { message.contains($0.localizedDescription) }.map { String(describing: $0) } ?? known ?? "unclassified"
        pending[turn]?.failureCode = code
        pending[turn]?.failureHash = Self.digest(message)
        event(turn: turn, name: "failure.\(code)")
    }

    func level(turn: UUID, value: Float) {
        guard value.isFinite, let row = pending[turn] else { return }
        pending[turn]?.metrics["level_events"] = (row.metrics["level_events"] ?? 0) + 1
        pending[turn]?.metrics["peak_level"] = max(row.metrics["peak_level"] ?? 0, Double(value))
    }

    func isPending(_ turn: UUID) -> Bool { pending[turn] != nil }
    var pendingTurns: [UUID] { Array(pending.keys) }

    func flush(turn: UUID, terminal: String, status: String, uptime: Double,
               trace: [VoiceCommandTrace.Event], works: [VoiceTaskCoordinator.Work], traceDropped: Int = 0) {
        guard let p = pending[turn] else { return }
        let heard = p.input == "dictation" ? "" : p.heard
        let stages = Set(trace.map(\.stage))
        let route: String
        if stages.contains(.admissionDictation) || p.input == "dictation" { route = "dictation" }
        else if stages.contains(.admissionLocal) { route = "local" }
        else if stages.contains(.admissionRemote) { route = "remote" }
        else if stages.contains(.admissionClarify) { route = "clarify" }
        else if stages.contains(.admissionRefuse) { route = "refuse" }
        else { route = works.isEmpty ? "none" : "unknown" }
        let anchor = p.releasedAt > 0 ? p.releasedAt : p.beganAt
        let firstActivity = trace.filter {
            $0.stage == .executorBegin || $0.stage == .driverBegin || $0.stage == .workCreated
                || $0.stage == .nativeTextInsertionBegin
        }.map(\.monotonic).min()
        let dispatchAt = trace.filter { $0.stage == .driverBegin || $0.stage == .nativeTextInsertionBegin }
            .map(\.monotonic).min()
        var row: [String: Any] = [
            "schema_version": 2,
            "turn": turn.uuidString,
            "input": p.input,
            "heard": heard,
            "final_text": heard,
            "heard_kind": p.hasFinal ? "final" : p.lastPartial.isEmpty ? "none" : "partial",
            "last_partial": p.input == "dictation" ? "" : p.lastPartial,
            "partials": p.input == "dictation" ? [] : p.partials,
            "partial_revisions_dropped": p.dropped,
            "content_redacted": p.input == "dictation",
            "metrics": p.metrics,
            "failure_code": p.failureCode ?? NSNull(),
            "failure_sha256": p.failureHash ?? NSNull(),
            "heard_sha256": p.hasFinal ? p.finalHash : Self.digest(""),
            "heard_words": p.finalWords,
            "route": route,
            "terminal": terminal,
            "status": status,
            "submitted_uptime": p.submittedAt,
            "admitted_uptime": p.submittedAt,
            "began_uptime": p.beganAt,
            "released_uptime": p.releasedAt,
            "flushed_uptime": uptime,
            "collection_ms": max(0, uptime - anchor) * 1000,
            "trace_dropped_global": traceDropped,
            "works_created": works.count,
            "executor_starts": trace.filter { $0.stage == .executorBegin }.count,
            "dispatches": trace.filter { $0.stage == .driverBegin }.count,
            "native_text_insertions": trace.filter { $0.stage == .nativeTextInsertionBegin }.count,
            "known_mutation_calls": trace.filter {
                $0.stage == .nativeTextInsertionBegin
                    || ($0.stage == .driverBegin && [.launchApp, .foreground, .typeText, .pressKey].contains($0.tool))
            }.count,
            "uncategorized_driver_calls": trace.filter { $0.stage == .driverBegin && $0.tool == .other }.count,
            "tools": trace.filter { $0.stage == .driverBegin }
                .compactMap { $0.tool?.rawValue },
            "trace": trace.map { e in
                var r: [String: Any] = ["stage": e.stage.rawValue,
                                        "monotonic": e.monotonic]
                if let task = e.task { r["task"] = task.uuidString }
                if let tool = e.tool { r["tool"] = tool.rawValue }
                return r
            },
            "works": works.map { w in
                [
                    "id": w.id.uuidString,
                    "request_sha256": Self.digest(w.request),
                    "application": w.spec.application ?? NSNull(),
                    "window_id": w.spec.windowID ?? NSNull(),
                    "outcome": Self.outcomeCode(w.outcome),
                    "active": w.active,
                    "awaiting_answer": w.awaitingAnswer,
                    "dispatched_effect": w.dispatchedEffect,
                    "elapsed_ms": w.elapsedMs,
                    "history_sha256": Self.digest(w.history.joined(separator: "\n")),
                ] as [String: Any]
            },
        ]
        if !["grace_timeout", "cancelled", "no_speech"].contains(terminal) {
            row["settle_ms"] = max(0, uptime - anchor) * 1000
        }
        if let firstActivity { row["first_activity_ms"] = max(0, firstActivity - anchor) * 1000 }
        if let dispatchAt {
            row["dispatch_ms"] = max(0, dispatchAt - anchor) * 1000
        }
        guard append(row, to: file) else { return }
        pending.removeValue(forKey: turn)
        finished.insert(turn)
        p.grace?.cancel()
        event(turn: turn, name: "terminal.\(terminal)", at: uptime)
        onTerminal?(row)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func outcomeCode(_ outcome: VoiceTaskCoordinator.Work.Outcome?) -> String {
        switch outcome {
        case .done: return "done"
        case .alreadyDone: return "alreadyDone"
        case .blocked: return "blocked"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .uncertain: return "uncertain"
        case nil: return "pending"
        }
    }
}

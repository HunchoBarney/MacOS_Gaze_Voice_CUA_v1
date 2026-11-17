import AppKit
import Darwin
import Foundation

@MainActor
final class VoiceNormalQualification {
    static let corpusSHA256 = "cbcb22aeacf7344ec0c6e422dcfc43f26583ae08641ffd8463527dfae5ad27a5"
    static private(set) var activeProfile: Profile?

    enum Mode: String { case physical, typedObserver = "typed-observer" }
    enum Failure: Error { case invalidProfile, storage }

    struct Profile {
        let directory: URL
        let mode: Mode
        let budget: SemanticRequestBudget?
        let remoteReasoningPermitted = false
    }

    static func profile(environment env: [String: String], arguments: [String]) throws -> Profile? {
        let argument = arguments.contains("--p3-normal-qualification")
        guard argument || env["JARVIS_P3_NORMAL_QUALIFICATION"] != nil
                || env["JARVIS_P3_NORMAL_DIRECTORY"] != nil else { return nil }
        guard let value = env["JARVIS_P3_NORMAL_QUALIFICATION"], let mode = Mode(rawValue: value),
              let path = env["JARVIS_P3_NORMAL_DIRECTORY"],
              let evidence = env["JARVIS_VOICE_EVIDENCE_DIR"] else { throw Failure.invalidProfile }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path == URL(fileURLWithPath: evidence).standardizedFileURL.path,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Failure.invalidProfile
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("witness.jsonl").path) else {
            throw Failure.invalidProfile
        }
        switch mode {
        case .physical:
            guard argument, env["JARVIS_P3_GUI_AUDIT"] == nil,
                  !arguments.contains("--p3-user-audit"),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent("requests.jsonl").path) else {
                throw Failure.invalidProfile
            }
            let budget = try SemanticRequestBudget(directory: root, corpusSHA256: corpusSHA256)
            guard budget.authorization.maximumRequests <= 5 else { throw Failure.invalidProfile }
            return Profile(directory: root, mode: mode, budget: budget)
        case .typedObserver:
            guard !argument, arguments.contains("--p3-user-audit"),
                  env["JARVIS_P3_GUI_AUDIT"] == "1", env["JARVIS_P3_GUI_AUDIT_ROUTING_ONLY"] == "1",
                  let id = env["JARVIS_P3_GUI_AUDIT_RUN_ID"], !id.isEmpty, id.utf8.count <= 40,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 }) else { throw Failure.invalidProfile }
            return Profile(directory: root, mode: mode, budget: nil)
        }
    }

    static func preflight() {
        do {
            activeProfile = try profile(environment: ProcessInfo.processInfo.environment,
                                        arguments: ProcessInfo.processInfo.arguments)
        } catch {
            fputs("BLOCKED: invalid normal-app qualification profile; no GUI or capture started.\n", stderr)
            exit(2)
        }
    }

    static func install(evidence: VoiceTurnEvidence?, lane: String) -> VoiceNormalQualification? {
        guard let configuration = activeProfile else { return nil }
        do {
            guard let evidence, evidence.writable else { throw Failure.storage }
            let observer = try VoiceNormalQualification(configuration: configuration,
                executableSHA256: evidence.executableSHA256, lane: lane)
            observer.attach(to: evidence)
            return observer
        } catch {
            fputs("BLOCKED: normal-app qualification observer unavailable; no capture started.\n", stderr)
            exit(2)
        }
    }

    static func isMutation(stage: String, tool: String?) -> Bool {
        stage == "command.nativeActivationBegin"
            || stage == "command.nativeUnhideBegin"
            || stage == "command.nativeTextInsertionBegin"
            || (stage == "command.driverBegin"
                && tool.map { ["launchApp", "foreground", "typeText", "pressKey"].contains($0) } == true)
    }

    let configuration: Profile
    private let writer: VoiceNormalWitnessWriter
    private let windowProbe: @Sendable () -> [String: Any]
    private let foregroundProbe: @Sendable () -> [String: Any]
    private var active: [UUID: Double] = [:]
    private lazy var sampler = VoiceNormalWindowSampler(
        writer: writer, windowProbe: windowProbe, foregroundProbe: foregroundProbe)
    private var workState: [UUID: Bool] = [:]

    init(configuration: Profile, executableSHA256: String, lane: String,
         windowProbe: @escaping @Sendable () -> [String: Any] = VoiceNormalQualification.windowObservation,
         foregroundProbe: @escaping @Sendable () -> [String: Any] = VoiceNormalQualification.foregroundObservation) throws {
        guard lane == "RealtimeVoiceLane", executableSHA256.count == 64 else { throw Failure.invalidProfile }
        self.configuration = configuration
        self.windowProbe = windowProbe
        self.foregroundProbe = foregroundProbe
        writer = try VoiceNormalWitnessWriter(directory: configuration.directory, mode: configuration.mode.rawValue)
        append(["kind": "startup", "schema_version": 1, "witness_protocol_version": 3,
                "controller": "VoiceController", "lane": lane,
                "mode": configuration.mode.rawValue, "pid": getpid(),
                "run_id": configuration.directory.lastPathComponent, "corpus_sha256": Self.corpusSHA256,
                "executable_sha256": executableSHA256, "monotonic": ProcessInfo.processInfo.systemUptime,
                "maximum_requests": configuration.mode == .physical
                    ? configuration.budget?.authorization.maximumRequests ?? 0 : 1,
                "remote_reasoning_permitted": false, "saved_audio": false, "saved_screenshots": false])
        guard writer.flush() else { throw Failure.storage }
        append(["kind": "work_state", "active_work_ids": [], "work_ids": [],
                "monotonic": ProcessInfo.processInfo.systemUptime])
    }

    func attach(to evidence: VoiceTurnEvidence) {
        let journal = evidence.onJournal
        evidence.onJournal = { [weak self] row in
            journal?(row)
            self?.observe(row)
        }
        let terminal = evidence.onTerminal
        evidence.onTerminal = { [weak self] row in
            terminal?(row)
            self?.settled(row)
        }
    }

    func preparation(_ stage: String, at: Double) {
        append(["kind": "preparation", "stage": stage, "monotonic": at])
    }

    func worksChanged(_ works: [VoiceTaskCoordinator.Work]) {
        guard Set(works.map(\.id)).count == works.count else {
            writer.fail("duplicate_work_identity"); return
        }
        let state = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0.active) })
        guard state != workState else { return }
        workState = state
        append(["kind": "work_state", "active_work_ids": works.filter(\.active).map { $0.id.uuidString },
                "work_ids": works.map { $0.id.uuidString }, "monotonic": ProcessInfo.processInfo.systemUptime])
    }

    private func observe(_ row: [String: Any]) {
        guard let text = row["turn"] as? String, let turn = UUID(uuidString: text),
              let stage = row["stage"] as? String else { return }
        let now = ProcessInfo.processInfo.systemUptime
        active = active.filter { $0.value >= now }
        if stage == "opened" {
            active[turn] = now + 180
            if configuration.mode == .typedObserver {
                if let data = Self.encodeSnapshot(foregroundProbe(), turn: turn, kind: "baseline") {
                    appendEncoded(data)
                }
                sampler.update(turn: turn, until: now + 180)
            } else {
                sampler.update(turn: turn, until: now + 180, baseline: true)
            }
        } else if active[turn] != nil, stage == "released" {
            active[turn] = now + 30
            sampler.update(turn: turn, until: now + 30)
        } else if active[turn] == nil, stage.hasPrefix("command.") {
            append(["kind": "late_activity", "turn": text, "stage": stage, "monotonic": now])
            active[turn] = now + 3
            sampler.update(turn: turn, until: now + 3)
        }
    }

    private func settled(_ row: [String: Any]) {
        guard let text = row["turn"] as? String, let turn = UUID(uuidString: text) else { return }
        if configuration.mode == .physical, !["voice", "dictation"].contains(row["input"] as? String ?? "") {
            writer.fail("nonphysical_input")
        }
        active[turn] = ProcessInfo.processInfo.systemUptime + 3
        append(["kind": "settled", "turn": text, "input": row["input"] ?? "",
                "terminal": row["terminal"] ?? "", "monotonic": ProcessInfo.processInfo.systemUptime])
        sampler.update(turn: turn, until: ProcessInfo.processInfo.systemUptime + 3)
    }

    nonisolated static func foregroundObservation() -> [String: Any] {
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier ?? 0
        let bundle = front?.bundleIdentifier ?? ""
        return ["monotonic": ProcessInfo.processInfo.systemUptime,
                "frontmost_pid": pid, "frontmost_app": bundle]
    }

    nonisolated static func windowObservation() -> [String: Any] {
        let before = foregroundObservation()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        var after = foregroundObservation()
        let pid = after["frontmost_pid"] as? pid_t ?? 0
        let bundle = after["frontmost_app"] as? String ?? ""
        let coherent = pid > 0 && !bundle.isEmpty
            && before["frontmost_pid"] as? pid_t == pid && before["frontmost_app"] as? String == bundle
        let visible = windows.compactMap { row -> [String: Any]? in
            guard coherent, let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = row[kCGWindowNumber as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber,
                  width.doubleValue.isFinite, height.doubleValue.isFinite,
                  width.doubleValue > 0, height.doubleValue > 0 else { return nil }
            return ["pid": owner, "window_id": id, "width": width, "height": height]
        }
        after["window_query_began"] = before["monotonic"]
        after["window_probe_complete"] = coherent
        after["visible_windows"] = visible
        return after
    }

    nonisolated static func encodeSnapshot(_ observation: [String: Any], turn: UUID, kind: String) -> Data? {
        var row = observation
        row["kind"] = kind
        row["turn"] = turn.uuidString
        return try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    }

    private func append(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else {
            writer.fail("encoding_failed"); return
        }
        appendEncoded(data)
    }

    private func appendEncoded(_ encoded: Data) {
        writer.append(encoded)
    }

    func stop() {
        sampler.stop()
        active.removeAll()
        append(["kind": "stopped", "monotonic": ProcessInfo.processInfo.systemUptime])
        writer.stop()
    }
}

final class VoiceNormalWitnessWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let handle: FileHandle
    private let health: URL
    private let mode: String
    private let runID: String
    private var accepting = true
    private var pending = 0
    private var rows = 0
    private var bytes = 0
    private var failure: String?
    private var closed = false
    private var lastHealth: Double = 0

    init(directory: URL, mode: String,
         queue: DispatchQueue = DispatchQueue(label: "jev.voice.witness-writer", qos: .userInitiated)) throws {
        self.queue = queue
        self.mode = mode
        runID = directory.lastPathComponent
        health = directory.appendingPathComponent("witness-health.json")
        let file = directory.appendingPathComponent("witness.jsonl")
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        writeHealth()
    }

    func append(_ encoded: Data, completed: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        guard accepting else { lock.unlock(); completed(); return }
        guard pending < 128 else {
            accepting = false
            lock.unlock()
            queue.async { self.recordFailure("writer_backpressure") }
            completed()
            return
        }
        pending += 1
        queue.async {
            defer {
                self.lock.lock()
                self.pending -= 1
                self.lock.unlock()
                completed()
            }
            guard self.failure == nil, !self.closed else { return }
            var data = encoded
            data.append(10)
            guard self.rows < 25_000, self.bytes + data.count <= 32 * 1024 * 1024 else {
                self.recordFailure("capacity_exceeded"); return
            }
            do {
                try self.handle.write(contentsOf: data)
                self.rows += 1
                self.bytes += data.count
                if self.rows == 1 || ProcessInfo.processInfo.systemUptime - self.lastHealth >= 1 {
                    self.writeHealth()
                }
            } catch { self.recordFailure("writer_failed") }
        }
        lock.unlock()
    }

    func fail(_ reason: String) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        accepting = false
        queue.async { self.recordFailure(reason) }
        lock.unlock()
    }

    func flush() -> Bool {
        queue.sync {
            writeHealth()
            return failure == nil
        }
    }

    func stop() {
        lock.lock()
        accepting = false
        lock.unlock()
        queue.sync {
            guard !closed else { return }
            do { try handle.close() } catch { recordFailure("close_failed") }
            closed = true
            writeHealth()
        }
    }

    private func recordFailure(_ reason: String) {
        if failure == nil { failure = reason }
        lock.lock()
        accepting = false
        lock.unlock()
        writeHealth()
    }

    private func writeHealth() {
        let row: [String: Any] = ["schema_version": 1, "writable": failure == nil,
                                 "failure": failure ?? NSNull(), "rows": rows, "bytes": bytes,
                                 "pid": getpid(), "mode": mode, "run_id": runID]
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try data.write(to: health, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: health.path)
            lastHealth = ProcessInfo.processInfo.systemUptime
        } catch {
            if failure == nil { failure = "health_failed" }
            lock.lock()
            accepting = false
            lock.unlock()
        }
    }
}

private final class VoiceNormalWindowSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "voice.qualification.windows", qos: .userInitiated)
    private let windowQueue = DispatchQueue(label: "voice.qualification.inventory", qos: .userInitiated)
    private let writer: VoiceNormalWitnessWriter
    private let windowProbe: @Sendable () -> [String: Any]
    private let foregroundProbe: @Sendable () -> [String: Any]
    private var turns: [UUID: Double] = [:]
    private var baselines: Set<UUID> = []
    private var timer: DispatchSourceTimer?
    private var pending = 0
    private var windowInFlight = false
    private var stopped = false

    init(writer: VoiceNormalWitnessWriter, windowProbe: @escaping @Sendable () -> [String: Any],
         foregroundProbe: @escaping @Sendable () -> [String: Any]) {
        self.writer = writer
        self.windowProbe = windowProbe
        self.foregroundProbe = foregroundProbe
    }

    func update(turn: UUID, until: Double, baseline: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        turns[turn] = until
        if baseline { baselines.insert(turn) }
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source
            source.resume()
        }
    }

    func completed() {
        lock.lock()
        pending = max(0, pending - 1)
        lock.unlock()
    }

    private func sample() {
        lock.lock()
        turns = turns.filter { $0.value >= ProcessInfo.processInfo.systemUptime }
        guard !stopped, !turns.isEmpty else {
            timer?.cancel(); timer = nil
            lock.unlock()
            return
        }
        guard pending + turns.count <= 128 else {
            stopped = true; timer?.cancel(); timer = nil
            lock.unlock()
            writer.fail("sampling_backpressure")
            return
        }
        let batch = turns.keys.map { ($0, baselines.contains($0)) }
        for (turn, _) in batch { baselines.remove(turn) }
        pending += batch.count
        lock.unlock()
        let observation = foregroundProbe()
        for (turn, baseline) in batch {
            if let data = VoiceNormalQualification.encodeSnapshot(
                observation, turn: turn, kind: baseline ? "baseline" : "foreground") {
                writer.append(data) { [weak self] in self?.completed() }
            } else {
                completed()
                writer.fail("sampling_encoding_failed")
            }
        }
        sampleWindows(turns: batch.map(\.0))
    }

    private func sampleWindows(turns: [UUID]) {
        lock.lock()
        guard !stopped, !windowInFlight else {
            lock.unlock()
            return
        }
        guard pending + turns.count <= 128 else {
            stopped = true
            timer?.cancel(); timer = nil
            lock.unlock()
            writer.fail("sampling_backpressure")
            return
        }
        windowInFlight = true
        pending += turns.count
        lock.unlock()
        windowQueue.async { [self] in
            defer {
                lock.lock()
                windowInFlight = false
                lock.unlock()
            }
            let observation = windowProbe()
            guard let began = observation["window_query_began"] as? Double, began.isFinite,
                  let ended = observation["monotonic"] as? Double, ended.isFinite, began <= ended,
                  observation["window_probe_complete"] is Bool else {
                for _ in turns { completed() }
                writer.fail("invalid_window_observation")
                return
            }
            for turn in turns {
                if let data = VoiceNormalQualification.encodeSnapshot(observation, turn: turn, kind: "window") {
                    writer.append(data) { [weak self] in self?.completed() }
                } else {
                    completed()
                    writer.fail("sampling_encoding_failed")
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        turns.removeAll(); baselines.removeAll()
        timer?.cancel(); timer = nil
        lock.unlock()
        queue.sync {}
        windowQueue.sync {}
    }
}

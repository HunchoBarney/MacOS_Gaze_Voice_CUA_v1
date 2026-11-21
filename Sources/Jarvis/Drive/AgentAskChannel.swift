import Darwin
import Foundation
import JarvisCore

/// The cross-process ask channel: agent MCP children (`--mcp-stdio`)
/// can't reach VoiceTaskCoordinator's continuations, so a parked ask is a
/// JSON file the child writes and the app answers. `asks/<id>.json` holds
/// the pending ask; `asks/<id>.answer` is the host's reply. The child
/// waits on the asks-dir watch until the deadline, then declines — a
/// timed-out ask is honest, never silently approved.
enum AgentAskChannel {
    /// One parked ask, as written by the child and read by the app.
    struct Pending: Sendable {
        var id: String
        var agent: String
        var kind: String          // "confirm" | "question" | "choice"
        var prompt: String
        /// `.choice` options — empty for confirm/question asks.
        var options: [String] = []
        var deadline: TimeInterval
        /// False when the host verified the `agent` claim against the
        /// roster and it isn't there — the child writes this field itself,
        /// so an unverifiable slug is shown marked rather than laundered
        /// into identity. True when no roster was supplied (no claim made).
        var trusted: Bool = true
    }

    /// Settable for tests — production always uses the shared support dir.
    static var asksDir = CuaDriveServer.supportDir
        .appendingPathComponent("asks", isDirectory: true)

    private static func askFile(_ id: String) -> URL {
        asksDir.appendingPathComponent("\(id).json")
    }
    private static func answerFile(_ id: String) -> URL {
        asksDir.appendingPathComponent("\(id).answer")
    }

    // MARK: - Child side (CuaDriveServer)

    /// Park the ask, wait for the host's answer file. Nil means declined
    /// or timed out — the DriveLoop treats nil as "no".
    static func request(_ ask: DriveLoop.Ask, agent: String,
                        timeout: TimeInterval = 120,
                        safetyInterval: Duration = .milliseconds(300)) async -> String? {
        let prompt: String
        let kind: String
        var options: [String] = []
        switch ask {
        case .confirm(let p): kind = "confirm"; prompt = p
        case .question(let p): kind = "question"; prompt = p
        case .choice(let p, let opts): kind = "choice"; prompt = p; options = opts
        }
        let id = UUID().uuidString
        let deadline = Date().timeIntervalSince1970 + timeout
        try? FileManager.default.createDirectory(at: asksDir,
                                                 withIntermediateDirectories: true)
        let body: [String: JSONValue] = [
            "id": .string(id), "agent": .string(agent), "kind": .string(kind),
            "prompt": .string(prompt), "options": .array(options.map { .string($0) }),
            "deadline": .number(deadline)]
        guard let data = try? JSONEncoder().encode(JSONValue.object(body)) else { return nil }
        try? data.write(to: askFile(id), options: .atomic)
        defer { try? FileManager.default.removeItem(at: askFile(id))
                try? FileManager.default.removeItem(at: answerFile(id)) }
        // The wait is the directory watch — the host's `.answer` write
        // fires the vnode event the moment it lands. The 300ms heartbeat
        // inside `changes` keeps the old cadence as the safety net, so a
        // wedged watch costs nothing over the previous poll.
        for await _ in changes(safetyInterval: safetyInterval) {
            if Task.isCancelled { return nil }
            if let text = try? String(contentsOf: answerFile(id), encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if Date().timeIntervalSince1970 >= deadline { return nil }
        }
        return nil
    }

    // MARK: - Directory watch

    /// One yield per asks-dir change. A vnode watch (DispatchSource on
    /// the directory descriptor) wakes on every file create/rename/
    /// delete — the ask landing and its answer both fire it — and a
    /// `safetyInterval` heartbeat bounds the worst case when the
    /// descriptor goes stale (the dir deleted and recreated between
    /// asks). The first yield is immediate so a consumer syncs existing
    /// state before it ever sleeps.
    ///
    /// Public contract unchanged — `pending()`/`answer()`/`discard()`
    /// still own the wire format; this only replaces "sleep 1s" as the
    /// host's wake mechanism:
    ///     for await _ in AgentAskChannel.changes() { syncAgentAsks() }
    static func changes(safetyInterval: Duration = .milliseconds(500)) -> AsyncStream<Void> {
        AsyncStream { continuation in
            try? FileManager.default.createDirectory(at: asksDir,
                                                     withIntermediateDirectories: true)
            var source: DispatchSourceFileSystemObject?
            let fd = open(asksDir.path, O_EVTONLY)
            if fd >= 0 {
                let watch = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .rename, .delete, .extend],
                    queue: .global(qos: .utility))
                watch.setEventHandler { continuation.yield(()) }
                watch.setCancelHandler { _ = close(fd) }
                watch.resume()
                source = watch
            }
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: safetyInterval)
                    continuation.yield(())
                }
            }
            continuation.onTermination = { _ in
                source?.cancel()
                heartbeat.cancel()
            }
            continuation.yield(())
        }
    }

    // MARK: - Host side (app)

    /// Pending asks on disk — stale rows past their deadline are dropped.
    /// `rosterSlugs` binds the self-reported `agent` field to the live
    /// roster: writes can't be validated (the child owns the file), so a
    /// slug outside the set lands in `Pending.trusted = false` for the
    /// consumer to mark rather than hide.
    static func pending(rosterSlugs: Set<String>? = nil) -> [Pending] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: asksDir.path)
        else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Pending] = []
        for name in names where name.hasSuffix(".json") {
            let url = asksDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let id = obj["id"]?.string, let prompt = obj["prompt"]?.string,
                  let kind = obj["kind"]?.string
            else { continue }
            var deadline = now + 60
            if case .number(let value)? = obj["deadline"] { deadline = value }
            if deadline < now {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let options = obj["options"]?.array?.compactMap(\.string) ?? []
            let slug = obj["agent"]?.string ?? "agent"
            out.append(Pending(id: id, agent: slug,
                               kind: kind, prompt: prompt, options: options,
                               deadline: deadline,
                               trusted: rosterSlugs.map { $0.contains(slug) } ?? true))
        }
        return out
    }

    /// The user's reply — the child's next poll picks it up.
    static func answer(_ id: String, _ answer: String) {
        try? FileManager.default.createDirectory(at: asksDir,
                                                 withIntermediateDirectories: true)
        try? answer.write(to: answerFile(id), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: askFile(id))
    }

    /// Host-side discard — the ask row goes away without an answer.
    static func discard(_ id: String) {
        try? FileManager.default.removeItem(at: askFile(id))
    }
}

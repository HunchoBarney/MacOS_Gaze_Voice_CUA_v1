import Foundation

/// Live gaze on the tracker's `/events` WebSocket — the stream the halo
/// and dwell hit-testing read, replacing per-verb `/snapshot` polling at
/// interactive rates.
///
/// Wire contract (`electron/externalApi.cjs`): on connect the server sends
/// `{type:"snapshot", snapshot:{...}}`, then `{type:"update",
/// changed:[slices], snapshot:{...}}` per change. Gaze lives in
/// `snapshot.gaze` with the same field names `GazeClient.decode` parses
/// (`x_px`/`y_px`/`confidence`/`updated_at`/`gaze_state`). Native clients
/// pass — browser WebSocket clients (which attach Origin) are rejected
/// upstream, so this is the sanctioned native consumer.
actor GazeStream {
    /// The freshest streamed sample, already decode-gated (stale and
    /// low-confidence samples throw in decode — we keep the last GOOD one
    /// and let `isFresh` gate the reader).
    private(set) var latestSample: GazeSample?

    /// Injectable event source — production opens the real WebSocket,
    /// tests feed canned JSON lines. Each element is one WS text frame.
    /// @Sendable because the pump Task invokes it off the caller's
    /// context — same posture as `TrackerControl.send`.
    private let frames: @Sendable () -> AsyncThrowingStream<String, Error>
    private var pump: Task<Void, Never>?
    /// Which pump generation is live — a replaced pump's teardown must
    /// not clobber its successor's `streaming` flag.
    private var pumpGeneration = 0
    /// True while a pump task is consuming frames — the socket dropping
    /// flips this, which is the reader's cue to re-`start()` (bounded)
    /// rather than trust a `latest()` that can only go stale.
    private(set) var streaming = false

    init(frames: (@Sendable () -> AsyncThrowingStream<String, Error>)? = nil) {
        self.frames = frames ?? { Self.socketFrames() }
    }

    static let shared = GazeStream()

    func latest() -> GazeSample? { latestSample }

    /// Good samples ingested so far — a reader compares it to know whether
    /// anything new arrived.
    private(set) var sequence = 0
    private var waiters: [Int: CheckedContinuation<Int, Never>] = [:]
    private var nextWaiter = 0

    /// Suspends until a sample newer than `seen` lands or `timeout`
    /// passes, and returns the current sequence. The gaze pump waits here
    /// so it reacts to each sample the moment it arrives instead of on a
    /// fixed poll.
    func waitForSample(after seen: Int, timeout: Duration) async -> Int {
        if sequence != seen { return sequence }
        nextWaiter += 1
        let id = nextWaiter
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeWaiter(id)
            }
        }
    }

    private func resumeWaiter(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(returning: sequence)
    }

    private func resumeAllWaiters() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(returning: sequence) }
    }

    /// Idempotent start — stops first so a tracker restart lands on a
    /// fresh socket.
    func start() {
        stop()
        pumpGeneration += 1
        let generation = pumpGeneration
        streaming = true
        pump = Task { [weak self] in await self?.consume(generation: generation) }
    }

    /// The frame consumer — actor-isolated so its teardown can flip
    /// `streaming` without racing a replacement start.
    private func consume(generation: Int) async {
        defer {
            // Only the live pump owns the flag — a superseded pump's
            // teardown can't mark its replacement dead.
            if pumpGeneration == generation { streaming = false }
        }
        do {
            for try await frame in frames() {
                if Task.isCancelled { return }
                ingest(frame)
            }
        } catch { /* socket died — streaming flips false; callers re-start */ }
    }

    /// Idempotent stop — cancels the consumer (the stream's own
    /// termination hook hangs up the WebSocket) and drops the held
    /// sample: a stopped stream has no gaze to offer, stale or not.
    func stop() {
        pump?.cancel()
        pump = nil
        streaming = false
        latestSample = nil
        resumeAllWaiters()
    }

    /// Parse one frame; keep the newest good gaze sample.
    private func ingest(_ frame: String) {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Only update-bearing frames matter; a bare snapshot handshake also
        // carries the gaze slice, so both shapes funnel through the slice.
        let snapshot = (obj["snapshot"] as? [String: Any]) ?? obj
        guard let gaze = snapshot["gaze"] as? [String: Any],
              let gazeData = try? JSONSerialization.data(withJSONObject: gaze),
              let sample = try? GazeClient.decode(gazeData) else { return }
        latestSample = sample
        sequence += 1
        resumeAllWaiters()
    }

    /// The production WebSocket — URLSession's task sends no Origin header,
    /// which is exactly what the tracker's browser-rejection lets through.
    private static func socketFrames() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let url = GazeClient.defaultBaseURL
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "ws"
            components?.path = "/events"
            guard let socketURL = components?.url else {
                continuation.finish(throwing: GazeError.unreachable); return
            }
            let task = URLSession.shared.webSocketTask(with: socketURL)
            task.resume()
            let pump = Task {
                defer { continuation.finish() }
                while !Task.isCancelled {
                    do {
                        switch try await task.receive() {
                        case .string(let text): continuation.yield(text)
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) {
                                continuation.yield(text)
                            }
                        @unknown default: continue
                        }
                    } catch { continuation.finish(throwing: error); return }
                }
            }
            continuation.onTermination = { _ in pump.cancel(); task.cancel() }
        }
    }
}

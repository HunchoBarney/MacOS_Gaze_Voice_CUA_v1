import Foundation
import os

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

    struct Observations: Sendable {
        fileprivate var revision: UInt64 = 0
        var epoch: UInt64 = 0
        var samples: [GazeSample] = []
    }

    static let continuityWindow: TimeInterval = 0.25
    private let observations = OSAllocatedUnfairLock(initialState: Observations())
    private var newestSourceTime: Date?

    nonisolated func liveObservations() -> Observations {
        observations.withLock { $0 }
    }

    nonisolated func isCurrent(_ snapshot: Observations) -> Bool {
        observations.withLock { $0.revision == snapshot.revision }
    }

    private func breakContinuity() {
        observations.withLock {
            $0.revision &+= 1
            $0.epoch &+= 1
            $0.samples.removeAll(keepingCapacity: true)
        }
    }

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
            if pumpGeneration == generation {
                breakContinuity()
                streaming = false
            }
        }
        do {
            for try await frame in frames() {
                if Task.isCancelled || pumpGeneration != generation { return }
                ingest(frame)
            }
        } catch { /* socket died — streaming flips false; callers re-start */ }
    }

    /// Idempotent stop — cancels the consumer (the stream's own
    /// termination hook hangs up the WebSocket) and drops the held
    /// sample: a stopped stream has no gaze to offer, stale or not.
    func stop() {
        breakContinuity()
        pump?.cancel()
        pump = nil
        streaming = false
        latestSample = nil
    }

    /// Parse one frame; keep the newest good gaze sample.
    private func ingest(_ frame: String) {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { breakContinuity(); return }
        // Only update-bearing frames matter; a bare snapshot handshake also
        // carries the gaze slice, so both shapes funnel through the slice.
        let snapshot = (obj["snapshot"] as? [String: Any]) ?? obj
        let changed = obj["changed"] as? [String]
        if snapshot["paused"] as? Bool == true || changed?.contains("paused") == true {
            latestSample = nil
            breakContinuity()
            return
        }
        if let changed, !changed.contains("gaze") { return }
        guard let gaze = snapshot["gaze"] as? [String: Any] else {
            if snapshot.keys.contains("gaze") || changed?.contains("gaze") == true { breakContinuity() }
            return
        }
        guard let gazeData = try? JSONSerialization.data(withJSONObject: gaze),
              let sample = try? GazeClient.decode(gazeData), let stamp = sample.observedAt else {
            if let stamp = GazeClient.captureTime(gaze["captured_at_ms"]) ?? GazeClient.receiptTime(gaze["updated_at"]),
               stamp <= Date(),
               stamp > (newestSourceTime ?? .distantPast) { newestSourceTime = stamp }
            breakContinuity()
            return
        }
        if let prior = newestSourceTime {
            if stamp == prior {
                var previous = latestSample
                previous?.updatedAt = sample.updatedAt
                if previous == nil || previous == sample { return }
            }
            guard stamp > prior else { breakContinuity(); return }
            if stamp.timeIntervalSince(prior) > Self.continuityWindow { breakContinuity() }
        }
        newestSourceTime = stamp
        latestSample = sample
        observations.withLock {
            $0.revision &+= 1
            $0.samples.append(sample)
            if $0.samples.count > 64 { $0.samples.removeFirst() }
        }
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

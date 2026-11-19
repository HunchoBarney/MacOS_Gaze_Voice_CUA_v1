import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: B7's shelf lays out top-right fixed chips whose rects feed
/// the candidate feed; B6's delegation messages carry the gaze context;
/// B5's implicit labels normalize to the tracker display and stop on
/// the first unsupported answer.
final class AgentShelfOverlayTests: XCTestCase {

    private func entry(_ slug: String, name: String = "Scout",
                       state: AgentShelfOverlay.State = .idle) -> AgentShelfOverlay.Entry {
        .init(slug: slug, name: name,
              colorHex: AgentCursor.palette(for: slug), state: state)
    }

    /// Chips stack top-right in top-left space — the first entry is the
    /// topmost, each row below the last.
    func testChipFramesStackTopRight() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rects = AgentShelfOverlay.chipFrames(
            [entry("a"), entry("b")], inFrame: frame)
        XCTAssertEqual(rects.count, 2)
        let a = rects["a"]!, b = rects["b"]!
        XCTAssertEqual(a.maxX, frame.maxX - AgentShelfOverlay.edgeInset,
                       accuracy: 0.5)
        XCTAssertEqual(a.minY, frame.minY + AgentShelfOverlay.edgeInset,
                       accuracy: 0.5)
        XCTAssertTrue(b.minY > a.maxY)
    }

    /// An empty roster retracts the shelf; the rect surface empties
    /// with it — a dead chip can't stay a gaze target.
    @MainActor
    func testEmptyRosterHides() {
        let shelf = AgentShelfOverlay()
        shelf.update([entry("a")], displayTopLeft: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(shelf.entries.count, 1)
        XCTAssertEqual(shelf.chipRects.count, 1)
        shelf.update([], displayTopLeft: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertTrue(shelf.entries.isEmpty)
        XCTAssertTrue(shelf.chipRects.isEmpty)
    }
}

/// The delegation seam — captures the request the coordinator sends.
@MainActor
private final class BridgeSpy: AgentBridging {
    var requests: [DelegationRequest] = []
    func roster() async -> [CompanionAgent] { [] }
    func delegate(_ request: DelegationRequest) async throws -> String {
        requests.append(request)
        return "{}"
    }
    func sendToAgent(slug: String, message: String) async throws -> String { "{}" }
    func agentMemory(slug: String) async throws -> String { "{}" }
    func interruptAgent(hint: String?) async -> String { "{}" }
}

/// In-memory key store — Config's init probes the store; tests never
/// touch the real Keychain.
private struct MemoryKeys: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

@MainActor
final class GazeDelegationTests: XCTestCase {

    private func coordinator() -> VoiceTaskCoordinator {
        let suite = "gaze-wiring-\(UUID().uuidString)"
        let config = Config(defaults: UserDefaults(suiteName: suite)!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                            environment: [:])
        return VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
                                    gazeService: GazeService(
                                        stream: GazeStream(frames: {
                                            AsyncThrowingStream { _ in }
                                        })))
    }

    /// A delegated task carries the referent — "watch that" means what
    /// the eyes were on, not a bare instruction.
    func testDelegationCarriesGazeContext() async {
        let c = coordinator()
        c.gazeContextProvider = { "Looking at: dom link \"Pricing\" in Safari" }
        let spy = BridgeSpy()
        c.agentBridge = spy
        _ = await c.delegateToAgent(task: "keep an eye on that")
        let message = spy.requests.last?.message ?? ""
        XCTAssertTrue(message.contains("keep an eye on that"))
        XCTAssertTrue(message.contains("Looking at: dom link \"Pricing\" in Safari"))
    }

    /// A cold feed leaves the message untouched — no fabricated gaze.
    func testColdGazeLeavesMessageBare() async {
        let c = coordinator()
        c.gazeContextProvider = { nil }
        let spy = BridgeSpy()
        c.agentBridge = spy
        _ = await c.delegateToAgent(task: "check this")
        XCTAssertEqual(spy.requests.last?.message, "check this")
    }
}

/// B5's commit-time label — normalized to the tracker display, deduped
/// per candidate, and permanently quiet after a HARD refusal (an older
/// tracker build without `implicit_sample` can't eat a POST per
/// commit) — while transient declines (a 409 `tracking_inactive`, a
/// dead socket) retry on the next commit.
final class ImplicitLabelerTests: XCTestCase {

    /// Fails the seam with `error` exactly once — a transient decline
    /// that later commits should retry through.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = true
        func fail<E: Error>(_ error: E) throws {
            lock.lock(); defer { lock.unlock() }
            if pending { pending = false; throw error }
        }
    }

    /// Lock-boxed POST capture — the seam is @Sendable; test spies
    /// serialize through the lock instead of racing a var.
    private final class Posts: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [(action: String, value: Any?)] = []
        var entries: [(action: String, value: Any?)] {
            lock.lock(); defer { lock.unlock() }; return _entries
        }
        var count: Int { entries.count }
        func record(_ action: String, _ value: Any?) {
            lock.lock(); _entries.append((action, value)); lock.unlock()
        }
    }

    private let candidate = IntentCandidate(
        id: "ax:1:2:t", kind: .axElement, frame: .zero, motorRect: .zero,
        role: "AXButton", label: "OK")

    private let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    /// The actor's seams inject at construction.
    private func labeler(
        posts: Posts, bounds: CGRect? = nil,
        rejection: TrackerControlError? = nil
    ) -> ImplicitLabeler {
        ImplicitLabeler(
            post: { action, value in
                if let rejection { throw rejection }
                posts.record(action, value)
            },
            displayBounds: { bounds })
    }

    func testCommitLabelsNormalizedPoint() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display)
        await labeler.commit(candidate, at: CGPoint(x: 250, y: 500), kind: .voice)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.entries[0].action, "implicit_sample")
        let value = posts.entries[0].value as? [String: Any]
        XCTAssertEqual(value?["x_norm"] as? Double, 0.25)
        XCTAssertEqual(value?["y_norm"] as? Double, 0.5)
        XCTAssertEqual(value?["kind"] as? String, "voice")
    }

    /// The user's own click labels with its kind and no candidate.
    func testClickLabelCarriesItsKind() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display)
        await labeler.label(at: CGPoint(x: 100, y: 900), kind: .click)
        let value = posts.entries.first?.value as? [String: Any]
        XCTAssertEqual(value?["kind"] as? String, "click")
        XCTAssertEqual(value?["y_norm"] as? Double, 0.9)
    }

    /// A point off the tracked display is no label — clamping would
    /// invent one at the edge (a click on the second monitor).
    func testOffDisplayPointIsNoLabel() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display)
        await labeler.label(at: CGPoint(x: 1500, y: 300), kind: .click)
        await labeler.commit(candidate, at: CGPoint(x: -5, y: 300), kind: .voice)
        XCTAssertEqual(posts.count, 0)
    }

    /// A commit on something window-sized says little about where the
    /// eyes were inside it.
    func testLargeCandidateIsNoLabel() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display)
        let window = IntentCandidate(
            id: "win:7", kind: .window, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            motorRect: CGRect(x: 0, y: 0, width: 800, height: 600), role: "window", label: "Doc")
        await labeler.commit(window, at: CGPoint(x: 400, y: 300), kind: .voice)
        XCTAssertEqual(posts.count, 0)
    }

    /// The same candidate inside the dedupe window doesn't re-label.
    func testDedupe() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display)
        await labeler.commit(candidate, at: CGPoint(x: 1, y: 1), kind: .voice)
        await labeler.commit(candidate, at: CGPoint(x: 2, y: 2), kind: .voice)
        XCTAssertEqual(posts.count, 1)
    }

    /// A hard rejection trips the breaker for the process's life — a
    /// tracker build that doesn't know `implicit_sample` can't eat a
    /// POST per commit — until `reset()` (tracker restart) re-opens it.
    func testBreakerTrips() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display,
                              rejection: .rejected(400))
        await labeler.commit(candidate, at: CGPoint(x: 1, y: 1), kind: .voice)
        XCTAssertEqual(posts.count, 0)
        let tripped = await labeler.tripped
        XCTAssertTrue(tripped)
        // The same labeler: still tripped, transport never consulted.
        await labeler.commit(candidate, at: CGPoint(x: 2, y: 2), kind: .voice)
        XCTAssertEqual(posts.count, 0)
        await labeler.reset()
        let open = await labeler.tripped
        XCTAssertFalse(open)
    }

    /// A 409 (`tracking_inactive`: paused, calibrating, a renderer
    /// reload) is a transient decline — the breaker stays open and the
    /// next commit retries the label.
    func testConflictDoesNotTrip() async {
        let posts = Posts()
        let once = Once()
        let bounds = display
        let labeler = ImplicitLabeler(
            post: { action, value in
                try once.fail(TrackerControlError.rejected(409))
                posts.record(action, value)
            },
            displayBounds: { bounds })
        await labeler.commit(candidate, at: CGPoint(x: 1, y: 1), kind: .voice)
        let tripped = await labeler.tripped
        XCTAssertFalse(tripped, "a 409 is transient — the breaker stays open")
        await labeler.commit(candidate, at: CGPoint(x: 2, y: 2), kind: .voice)
        XCTAssertEqual(posts.count, 1, "the next commit retries the label")
    }

    /// An unreachable tracker is not a refusal — the breaker stays
    /// open so a tracker that comes back keeps taking labels.
    func testUnreachableDoesNotTrip() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: display,
                              rejection: .unreachable)
        await labeler.commit(candidate, at: CGPoint(x: 1, y: 1), kind: .voice)
        let tripped = await labeler.tripped
        XCTAssertFalse(tripped, "unreachable is transient — the breaker stays open")
        XCTAssertEqual(posts.count, 0)
    }

    /// No display bounds, no label — a normalized point needs a frame.
    func testNoDisplayNoLabel() async {
        let posts = Posts()
        let labeler = labeler(posts: posts, bounds: nil)
        await labeler.commit(candidate, at: CGPoint(x: 1, y: 1), kind: .voice)
        XCTAssertEqual(posts.count, 0)
    }
}

import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: screen lock parks the tracker's camera/inference through the
/// same `paused` flag a manual pause uses — lock POSTs
/// `{"action":"set_paused","value":true}`, unlock POSTs `false`, and only
/// when the lock actually claimed the pause. A pause the user already set
/// must survive the cycle, and a tracker that respawned mid-lock re-parks
/// on its `.running` transition. The transport seam serves canned
/// snapshots and records POSTs — no socket is opened.
final class TrackerHostLockTests: XCTestCase {

    /// Records the control POSTs and answers /snapshot with the scripted
    /// paused flag — the whole wire the lock path speaks.
    private final class FakeTracker: @unchecked Sendable {
        var requests: [URLRequest] = []
        var snapshotPaused = false

        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            let path = request.url?.path ?? ""
            let payload: [String: Any] = path == "/snapshot"
                ? ["paused": snapshotPaused, "calibration_status": "loaded"]
                : ["ok": true]
            return (try JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
    }

    private var transport: FakeTracker!
    private var oldTransport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))!

    override func setUp() {
        super.setUp()
        transport = FakeTracker()
        let fake = transport!
        oldTransport = TrackerControl.transport
        TrackerControl.transport = { try fake.send($0) }
    }

    override func tearDown() {
        TrackerControl.transport = oldTransport
        transport = nil
        super.tearDown()
    }

    private func controlBodies() -> [[String: Any]] {
        transport.requests
            .filter { $0.url?.path == "/control" }
            .compactMap { request in
                guard let data = request.httpBody,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return obj
            }
    }

    private func runningHost() async -> TrackerHost {
        let host = TrackerHost()
        await host.installForTest(child: nil, attempts: 0, state: .running)
        return host
    }

    /// Lock on a live tracker parks it — one deterministic POST, and the
    /// host marks the pause as lock-owned so unlock knows it may undo it.
    func testLockPausesRunningTracker() async {
        let host = await runningHost()
        await host.simulateScreenLock(true)
        let bodies = controlBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?["action"] as? String, "set_paused")
        XCTAssertEqual(bodies.first?["value"] as? Bool, true)
        let pausedByLock = await host.pausedByLockForTest
        XCTAssertTrue(pausedByLock)
        let locked = await host.screenIsLockedForTest
        XCTAssertTrue(locked)
    }

    /// Unlock after a lock-park resumes — exactly one pause POST and one
    /// resume POST, nothing more.
    func testUnlockResumesWhatLockPaused() async {
        let host = await runningHost()
        await host.simulateScreenLock(true)
        await host.simulateScreenLock(false)
        let bodies = controlBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.last?["action"] as? String, "set_paused")
        XCTAssertEqual(bodies.last?["value"] as? Bool, false)
        let pausedByLock = await host.pausedByLockForTest
        XCTAssertFalse(pausedByLock)
    }

    /// The user's own pause is never claimed by the lock — and the unlock
    /// must not resurrect it.
    func testLockNeverClaimsAUsersPause() async {
        transport.snapshotPaused = true
        let host = await runningHost()
        await host.simulateScreenLock(true)
        await host.simulateScreenLock(false)
        XCTAssertTrue(controlBodies().isEmpty,
                      "a pause already present at lock time is the user's — no POSTs at all")
        let pausedByLock = await host.pausedByLockForTest
        XCTAssertFalse(pausedByLock)
    }

    /// A dead/stopped tracker takes no parking action — but the lock state
    /// is remembered, so a tracker coming up under a locked screen gets
    /// parked on its `.running` transition instead of burning the camera.
    func testTrackerStartingWhileLockedParksOnRunning() async {
        let host = TrackerHost()
        await host.installForTest(child: nil, attempts: 0, state: .stopped)
        await host.simulateScreenLock(true)
        XCTAssertTrue(controlBodies().isEmpty,
                      "no /control POST while nothing is running")
        // .running transition re-evaluates the persisted lock edge —
        // the didSet hops through a Task, so poll for the POST to land.
        await host.installForTest(child: nil, attempts: 0, state: .running)
        for _ in 0..<20 where controlBodies().isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let bodies = controlBodies()
        XCTAssertEqual(bodies.count, 1,
                       "a tracker respawning under a locked screen must re-park")
        XCTAssertEqual(bodies.first?["value"] as? Bool, true)
    }

    /// An unlock edge when nothing was parked is a no-op — no POSTs.
    func testUnlockWithoutParkIsQuiet() async {
        let host = await runningHost()
        await host.simulateScreenLock(false)
        XCTAssertTrue(controlBodies().isEmpty)
    }

    /// A tracker that dies while lock-parked clears the claim — the respawn
    /// owns parking again through the .running transition, not the stale flag.
    func testRespawnWhileLockedReparks() async {
        let host = await runningHost()
        await host.simulateScreenLock(true)
        XCTAssertEqual(controlBodies().count, 1)
        // Simulate the tracker dying mid-lock: state leaves .running, the
        // didSet clears pausedByLock, and the next .running re-parks.
        await host.installForTest(child: nil, attempts: 0, state: .stopped)
        let clearedClaim = await host.pausedByLockForTest
        XCTAssertFalse(clearedClaim, "the lock's pause claim dies with its tracker")
        await host.installForTest(child: nil, attempts: 0, state: .running)
        for _ in 0..<20 where controlBodies().count < 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controlBodies().count, 2,
                       "the respawned tracker must be re-parked under the still-locked screen")
    }

    /// A transport that can hold a request open — the race tests park a
    /// suspend inside it, flip the lock edge underneath, then release and
    /// check which POSTs landed. `paused` models the tracker's own flag:
    /// a POST flips it only when the send actually returns, so a read
    /// during a suspended unpause still sees the old pause.
    @MainActor
    private final class GatedTracker {
        var posts: [[String: Any]] = []
        var paused = false
        /// Hold /snapshot until releaseSnapshot() — the park path's read.
        var gateSnapshot = false
        var snapshotStarted = false
        private var snapshotOpen = false
        /// Hold a set_paused(false) POST until releaseUnpause() — the
        /// resume path's write.
        var gateUnpause = false
        var unpauseStarted = false
        private var unpauseOpen = false
        var gatePause = false
        var pauseStarted = false
        var failPause = false
        private var pauseOpen = false

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url?.path ?? ""
            if path == "/control",
               let data = request.httpBody,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if gatePause, (obj["value"] as? Bool) == true {
                    pauseStarted = true
                    while !pauseOpen {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if failPause { throw URLError(.networkConnectionLost) }
                }
                if gateUnpause, (obj["value"] as? Bool) == false {
                    unpauseStarted = true
                    while !unpauseOpen {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                posts.append(obj)
                if let value = obj["value"] as? Bool { paused = value }
            }
            if path == "/snapshot" {
                if gateSnapshot {
                    snapshotStarted = true
                    while !snapshotOpen {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                let payload = try JSONSerialization.data(withJSONObject: ["paused": paused,
                                                                          "calibration_status": "loaded"])
                return (payload, HTTPURLResponse(url: request.url!, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil)!)
            }
            let payload = try JSONSerialization.data(withJSONObject: ["ok": true])
            return (payload, HTTPURLResponse(url: request.url!, statusCode: 200,
                                             httpVersion: nil, headerFields: nil)!)
        }

        func releaseSnapshot() { snapshotOpen = true }
        func releaseUnpause() { unpauseOpen = true }
        func releasePause() { pauseOpen = true }
    }

    @MainActor
    func testRetiredPauseReplyCannotClaimTheReplacementTracker() async {
        for (failedOldPost, replacementAlreadyPaused) in [(false, true), (false, false), (true, false)] {
            let retired = GatedTracker()
            retired.gatePause = true
            retired.failPause = failedOldPost
            TrackerControl.transport = { try await retired.send($0) }
            let host = await runningHost()
            let park = Task { await host.simulateScreenLock(true) }
            for _ in 0..<100 where !retired.pauseStarted {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(retired.pauseStarted)
            await host.installForTest(child: nil, attempts: 0, state: .stopped)
            let replacement = GatedTracker()
            replacement.paused = replacementAlreadyPaused
            TrackerControl.transport = { try await replacement.send($0) }
            await host.installForTest(child: nil, attempts: 0, state: .running)
            retired.releasePause()
            await park.value
            if !replacementAlreadyPaused {
                for _ in 0..<100 {
                    if await host.pausedByLockForTest { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            let claimed = await host.pausedByLockForTest
            XCTAssertEqual(claimed, !replacementAlreadyPaused)
            XCTAssertEqual(replacement.posts.count, replacementAlreadyPaused ? 0 : 1)
            XCTAssertTrue(replacement.paused)
            await host.simulateScreenLock(false)
            XCTAssertEqual(replacement.paused, replacementAlreadyPaused)
            XCTAssertEqual(replacement.posts.count, replacementAlreadyPaused ? 0 : 2)
            XCTAssertEqual(retired.posts.count, failedOldPost ? 0 : 1)
            await host.installForTest(child: nil, attempts: 0, state: .stopped)
        }
    }

    /// The race the converge loop fixes: an unlock landing while the
    /// park's status read is suspended must veto the pause POST — a
    /// single-pass body would let it land on an unlocked screen and
    /// nothing would ever undo it.
    @MainActor
    func testUnlockLandingMidParkLeavesNoPark() async {
        let gated = GatedTracker()
        gated.gateSnapshot = true
        TrackerControl.transport = { try await gated.send($0) }
        let host = await runningHost()
        // The park suspends inside the gated /snapshot read — that's the
        // window the unlock must interleave into.
        let park = Task { await host.simulateScreenLock(true) }
        for _ in 0..<100 where !gated.snapshotStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gated.snapshotStarted, "the park never reached its status read")
        // The unlock's own applyLockParking run sees no claim yet and
        // returns early — correct, since the veto belongs to the parked
        // call's post-suspend re-check.
        await host.simulateScreenLock(false)
        gated.releaseSnapshot()
        await park.value
        XCTAssertTrue(gated.posts.isEmpty,
                      "an unlock mid-park must veto the pause POST, not let it land")
        let pausedByLock = await host.pausedByLockForTest
        XCTAssertFalse(pausedByLock)
    }

    /// The other half of the race: a re-lock landing while the resume's
    /// unpause POST is suspended must end parked — the loop hands the
    /// tracker right back instead of leaving an unlocked screen unpaused
    /// under a locked screen.
    @MainActor
    func testRelockLandingMidResumeReparks() async {
        let gated = GatedTracker()
        TrackerControl.transport = { try await gated.send($0) }
        let host = await runningHost()
        await host.simulateScreenLock(true)
        XCTAssertEqual(gated.posts.count, 1)
        XCTAssertEqual(gated.posts.first?["value"] as? Bool, true)
        // Unpause gates at the POST — the lock edge lands while it flies.
        gated.gateUnpause = true
        let unlock = Task { await host.simulateScreenLock(false) }
        for _ in 0..<100 where !gated.unpauseStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gated.unpauseStarted, "the resume never reached its unpause POST")
        await host.simulateScreenLock(true)
        gated.releaseUnpause()
        await unlock.value
        for _ in 0..<100 where gated.posts.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(gated.posts.count, 3,
                       "re-lock mid-resume must loop back into the park")
        XCTAssertEqual(gated.posts.last?["value"] as? Bool, true,
                       "the converged state is parked, matching the locked screen")
        let pausedByLock = await host.pausedByLockForTest
        XCTAssertTrue(pausedByLock)
    }

    /// An unreachable tracker can't be parked — the failure is logged and
    /// the flag stays clear, so the unlock edge can't unpause a pause that
    /// never landed.
    func testLockWithUnreachableTrackerLeavesNoClaim() async {
        final class DeadTracker: @unchecked Sendable {
            func send(_ request: URLRequest) throws -> (Data, URLResponse) {
                throw URLError(.cannotConnectToHost)
            }
        }
        let dead = DeadTracker()
        TrackerControl.transport = { try dead.send($0) }
        let host = await runningHost()
        await host.simulateScreenLock(true)
        let pausedByLock = await host.pausedByLockForTest
        XCTAssertFalse(pausedByLock)
    }
}

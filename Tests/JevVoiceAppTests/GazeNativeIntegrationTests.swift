import Foundation
import XCTest
@testable import JevVoice

@MainActor
final class GazeNativeIntegrationTests: XCTestCase {
    private struct Keys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    @MainActor private final class Fixture {
        let channel = AsyncThrowingStream<String, Error>.makeStream()
        let suite = "GazeNativeIntegrationTests." + UUID().uuidString
        let defaults: UserDefaults
        let service: GazeService
        let coordinator: VoiceTaskCoordinator
        let frame = CGRect(x: 80, y: 80, width: 40, height: 40)
        let iso = ISO8601DateFormatter()
        var element = 1
        var pressed: [Int] = []
        var requests = 0
        var swapDuringFetch = false
        var readsBeforeReplacement: Int?
        var beforePress: (() -> Bool)?

        init(dwell: Bool = false) {
            let store = UserDefaults(suiteName: suite)!
            defaults = store
            DwellPolicy(mode: dwell ? .safe : .off, deniedApps: [], userMultiplier: 1).save(to: store)
            let stream = channel.stream
            service = GazeService(stream: GazeStream(frames: { stream }), defaults: store)
            let config = Config(defaults: store, keyStore: Keys(), openAIKeyStore: Keys(),
                                environment: [:], codexAuth: CodexAuth(binary: nil))
            config.sounds = false
            coordinator = VoiceTaskCoordinator(config: config, jevAPIKey: { "" }, gazeService: service,
                                              overlay: TargetOverlay(presentsPanels: false),
                                              resolver: AppResolver(listApps: { [] }),
                                              commandDriver: { _, _ in
                                                  XCTFail("unexpected driver request")
                                                  throw CancellationError()
                                              }, observeAgents: false)
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            service.cursorPoint = { nil }
            service.windowIDUnder = { _ in 7 }
            service.eventSink = { _ in }; service.staleSink = { _ in }
            service.labels = ImplicitLabeler(post: { _, _ in }, displayBounds: { nil })
            coordinator.captureActiveProbe = { false }
            service.enumerate = { [weak self] p in
                guard let self else { return .empty }
                return await coordinator.witnessedGazeRoster(at: p, capture: { point in
                    CommittedGazeHit.capture(at: point, read: { [weak self] in self?.hit(at: $0) },
                                             prepare: { [weak self] _ in self?.beforePress?() ?? true },
                                             press: { [weak self] node in self?.pressed.append(node); return true })
                }, enumerate: { _ in
                    self.requests += 1
                    if self.swapDuringFetch {
                        try? await Task.sleep(for: .milliseconds(70))
                        self.element += 1
                    }
                    return .init(candidates: [
                        IntentCandidate(id: "ax:42:7:s00000009:0", kind: .axElement,
                                        frame: self.frame, motorRect: self.frame, role: "AXButton", label: "Edit",
                                        pid: 42, windowID: 7, windowTitle: "Fixture")
                    ], windowID: 7)
                })
            }
            service.start()
        }

        func hit(at point: CGPoint) -> CommittedGazeHit.Hit<Int>? {
            guard frame.contains(point) else { return nil }
            if let remaining = readsBeforeReplacement {
                if remaining == 0 {
                    element += 1
                    readsBeforeReplacement = nil
                } else {
                    readsBeforeReplacement = remaining - 1
                }
            }
            return .init(element: element, window: 7, ancestors: [3], pid: 42, windowID: 7,
                         windowTitle: "Fixture", role: "AXButton", name: "Edit", detail: "", frame: frame, light: nil)
        }

        func send(x: Int = 100) {
            let capture = Date()
            channel.continuation.yield(#"{"snapshot":{"gaze":{"x_px":\#(x),"y_px":100,"confidence":0.9,"gaze_state":"fixation","captured_at_ms":\#(capture.timeIntervalSince1970 * 1000),"updated_at":"\#(iso.string(from: capture))"}}}"#)
        }

        func selected() async throws -> IntentCandidate {
            for _ in 0..<60 {
                send()
                try await Task.sleep(for: .milliseconds(40))
                if let hit = await service.commitTarget(lookBackSec: 0, recordSelection: false) { return hit.0 }
            }
            return try XCTUnwrap(nil as IntentCandidate?, "real scorer never selected the synthetic control")
        }

        func finish() {
            beforePress = nil
            service.stop()
            channel.continuation.finish()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testBareClickOnAnUnchangedLookPressesTheRetainedObjectOnce() async throws {
        let f = Fixture()
        defer { f.finish() }
        let candidate = try await f.selected()
        let onset = try XCTUnwrap(f.coordinator.currentGazeClickLease)
        XCTAssertEqual(candidate.gazeLease, onset)
        XCTAssertTrue(VoiceAdmissionPolicy.isBareGazeClick("Click."))
        let first = await f.coordinator.actuateCommitted(candidate, permitted: { f.coordinator.currentGazeClickLease == onset })
        let duplicate = await f.coordinator.actuateCommitted(candidate, permitted: { f.coordinator.currentGazeClickLease == onset })
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(f.pressed, [1])
    }

    func testOptedInContinuousLookDoesNotPressAgainOnRosterRefresh() async throws {
        let f = Fixture(dwell: true)
        defer { f.finish() }
        for _ in 0..<80 where f.pressed.isEmpty {
            f.send()
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(f.pressed, [1])
        let initialRequests = f.requests
        f.element = 2
        for _ in 0..<90 {
            f.send()
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertGreaterThanOrEqual(f.requests - initialRequests, 2)
        XCTAssertEqual(f.pressed, [1])
        for _ in 0..<10 {
            f.send(x: 145)
            try await Task.sleep(for: .milliseconds(40))
        }
        for _ in 0..<90 where f.pressed.count == 1 {
            f.send()
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(f.pressed, [1, 2])
    }

    func testSameLookingReplacementDuringDelayedRosterIsNotWitnessed() async throws {
        let f = Fixture()
        defer { f.finish() }
        f.swapDuringFetch = true
        let selected = try await f.selected()
        XCTAssertGreaterThan(f.element, 1)
        XCTAssertNil(f.service.batch.nativeWitness)
        XCTAssertNil(f.coordinator.currentGazeClickLease)
        let landed = await f.coordinator.actuateCommitted(selected)
        XCTAssertFalse(landed)
        XCTAssertTrue(f.pressed.isEmpty)
    }

    func testFinalRetainedReadRejectsAnIdenticalLookingReplacement() async throws {
        let f = Fixture()
        defer { f.finish() }
        let selected = try await f.selected()
        XCTAssertNotNil(f.coordinator.currentGazeClickLease)
        f.readsBeforeReplacement = 1
        let landed = await f.coordinator.actuateCommitted(selected)
        XCTAssertEqual(f.element, 2)
        XCTAssertFalse(landed)
        XCTAssertTrue(f.pressed.isEmpty)
    }

    func testOldFixationCannotBeReadAfterNewWitnessBeforeScorerUpdate() async throws {
        let f = Fixture()
        defer { f.finish() }
        let candidate = try await f.selected()
        let first = try XCTUnwrap(f.service.batch.nativeWitness)
        var checked = false
        f.service.speechHint = {
            if !checked, let witness = f.service.batch.nativeWitness, witness != first {
                checked = true
                XCTAssertNil(f.coordinator.currentGazeClickLease)
                XCTAssertFalse(f.service.authorizes(candidate))
            }
            return nil
        }
        defer { f.service.speechHint = { nil } }
        f.element = 2
        for _ in 0..<75 where !checked {
            f.send()
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(checked)
        XCTAssertTrue(f.pressed.isEmpty)
    }

    func testPauseOnlyUpdateRevokesTheRetainedTargetWithoutAnotherGazeFrame() async throws {
        let f = Fixture()
        defer { f.finish() }
        let candidate = try await f.selected()
        XCTAssertNotNil(f.coordinator.currentGazeClickLease)
        f.channel.continuation.yield(#"{"changed":["paused"],"snapshot":{"paused":true}}"#)
        for _ in 0..<50 where !f.service.stream.liveObservations().samples.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(f.service.stream.liveObservations().samples.isEmpty)
        XCTAssertNil(f.coordinator.currentGazeClickLease)
        let landed = await f.coordinator.actuateCommitted(candidate)
        XCTAssertFalse(landed)
        XCTAssertTrue(f.pressed.isEmpty)
    }

    func testAdjacentGazeBetweenNativePreparationAndPressRevokesTheWrite() async throws {
        try await assertMovedDuringPreparationRefuses(x: 145)
    }

    func testChangedObservationInsideSameCachedFrameNeedsNewNativeProof() async throws {
        try await assertMovedDuringPreparationRefuses(x: 110)
    }

    private func assertMovedDuringPreparationRefuses(x: Int) async throws {
        let f = Fixture()
        defer { f.finish() }
        let selected = try await f.selected()
        XCTAssertNotNil(f.coordinator.currentGazeClickLease)
        var observedNeighbor = false
        f.beforePress = {
            f.send(x: x)
            let stream = f.service.stream
            for _ in 0..<100 where stream.liveObservations().samples.last?.x != Double(x) {
                Thread.sleep(forTimeInterval: 0.001)
            }
            observedNeighbor = stream.liveObservations().samples.last?.x == Double(x)
            return true
        }
        let landed = await f.coordinator.actuateCommitted(selected)
        XCTAssertTrue(observedNeighbor)
        XCTAssertFalse(landed)
        XCTAssertTrue(f.pressed.isEmpty)
    }
}

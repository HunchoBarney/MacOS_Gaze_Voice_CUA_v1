import Synchronization
import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: Realtime conversation finals are admitted exactly once
/// through the local admission session, and microphone permission polling
/// stays responsive, coalesced and revocable.
final class LocalSpeechTests: XCTestCase {
    @MainActor
    func testConversationRemoteFinalRecoversFromEmptyAndUsesExistingNativeAdmissionOnce() async throws {
        let conversation = ConversationSession()
        var context = VoiceAdmissionContext()
        context.targetAppID = "fixture.editor"; context.windowID = 42
        context.targetID = "fixture.editor.42"
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("queue owns execution") }
            owner.context = captured
            return owner
        }
        conversation.readContext = { context }
        conversation.interpret = { _, _, _ in
            XCTFail("clear native scroll must not call a model")
            return .init(kind: .clarify)
        }
        var executed: [String] = []
        let effect = expectation(description: "next nonempty turn")
        conversation.execute = { command in
            executed.append(command.text)
            effect.fulfill()
            return .init(verified: true, waitingForAnswer: false, message: "Scrolled.")
        }
        conversation.onControl = { _ in }
        let session = UUID(), connection = UUID()
        try conversation.startExternal(session: session)
        defer { conversation.stop() }
        let empty = try conversation.beginExternal(
            input: .init(connectionID: connection, itemID: "empty"), at: 1)
        XCTAssertTrue(conversation.commitExternal(empty, at: 2))
        await conversation.finishExternal(empty, text: "", at: 2.1)
        XCTAssertEqual(conversation.id, session)
        let next = try conversation.beginExternal(
            input: .init(connectionID: connection, itemID: "next"), at: 3)
        XCTAssertTrue(conversation.commitExternal(next, at: 4))
        await conversation.finishExternal(next, text: "scroll down", at: 4.1)
        await conversation.finishExternal(next, text: "scroll down", at: 4.2)
        await fulfillment(of: [effect], timeout: 2)
        XCTAssertEqual(executed, ["scroll down"])
        XCTAssertEqual(conversation.id, session)
    }

    @MainActor
    func testRealtimeAdmissionNeedsNoLocalProviderAndKeepsDictationLiteral() async throws {
        let owner = LocalSpeechSession { _ in XCTFail("admission is not execution") }
        let input = VoiceRealtimeInput(connectionID: UUID(), itemID: "dictation-1")
        let turn = owner.beginRemoteCapture(id: UUID(), mode: .dictation,
            connection: input.connectionID, now: 0)
        let premature = await owner.finishRemoteCapture("Open Calculator. Don't change forty-two.",
            turn: turn, input: input, now: 0.5)
        XCTAssertNil(premature)
        XCTAssertTrue(owner.commitRemoteCapture(turn, input: input, now: 1))
        let final = await owner.finishRemoteCapture("Open Calculator. Don't change forty-two.",
            turn: turn, input: input, now: 1.1)
        XCTAssertEqual(final?.route, .dictation)
        XCTAssertEqual(final?.text, "Open Calculator. Don't change forty-two.")
        XCTAssertEqual(final?.realtimeInput, input)
        let duplicate = await owner.finishRemoteCapture("duplicate", turn: turn, input: input, now: 1.2)
        XCTAssertNil(duplicate)
    }

    @MainActor
    func testRealtimeEmptyFinalRetiresOnlyItsTurnAndRejectsLateOrForeignFinals() async throws {
        let owner = LocalSpeechSession { _ in XCTFail("no automatic execution") }
        let input = VoiceRealtimeInput(connectionID: UUID(), itemID: "empty")
        let first = owner.beginRemoteCapture(id: UUID(), mode: .command,
            connection: input.connectionID, now: 0)
        XCTAssertTrue(owner.commitRemoteCapture(first, input: input, now: 1))
        let empty = await owner.finishRemoteCapture(" \n", turn: first, input: input, now: 1.1)
        XCTAssertNil(empty)
        let nextInput = VoiceRealtimeInput(connectionID: input.connectionID, itemID: "next")
        let next = owner.beginRemoteCapture(id: UUID(), mode: .command,
            connection: input.connectionID, now: 2)
        XCTAssertTrue(owner.commitRemoteCapture(next, input: nextInput, now: 3))
        let stale = await owner.finishRemoteCapture("scroll down", turn: first, input: input, now: 3.1)
        let foreign = await owner.finishRemoteCapture("scroll down", turn: next, input: input, now: 3.1)
        XCTAssertNil(stale)
        XCTAssertNil(foreign)
        let final = await owner.finishRemoteCapture("What can you help with?", turn: next, input: nextInput, now: 3.2)
        XCTAssertEqual(final?.text, "What can you help with?")
        XCTAssertEqual(final?.realtimeInput, nextInput)
    }

    func testConversationAdmissionIsOneShotAndCancellationRevokesIt() throws {
        for cancelled in [false, true] {
            var gate = VoiceTurnGate()
            let turn = gate.begin(mode: .command, ready: true, now: 1)
            XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
            XCTAssertTrue(gate.release(turn, acceptedFrames: 1, now: 2))
            XCTAssertNotNil(gate.finalize(turn, text: "scroll down",
                proposal: VoiceProposal(route: .local, intent: "scroll"),
                drainedFrames: 1, now: 2.1))
            if cancelled { gate.cancel(turn) }
            let admitted = gate.consume(turn)
            XCTAssertEqual(admitted != nil, !cancelled)
            XCTAssertNil(gate.consume(turn))
        }
    }

    func testSemanticResolutionCannotConsumeAConfirmationOrChangedTarget() {
        for reason in ["unclear_request", "ungrounded_target", "confirmation_required", "target_changed",
                       "ask_changed", "ambiguous_ask", "ambiguous_critical_value", "contradictory_request"] {
            var gate = VoiceTurnGate()
            let turn = gate.begin(mode: .command, ready: true, now: 1)
            XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
            XCTAssertTrue(gate.release(turn, acceptedFrames: 1, now: 2))
            XCTAssertNotNil(gate.finalize(turn, text: "A complete final",
                proposal: VoiceProposal(route: .clarify, intent: "blocked", reason: reason),
                drainedFrames: 1, now: 2.1))
            XCTAssertNil(gate.consume(turn))
            let resolved = gate.consume(turn, resolvingClarification: true)
            XCTAssertEqual(resolved != nil, ["unclear_request", "ungrounded_target"].contains(reason), reason)
            XCTAssertNil(gate.consume(turn, resolvingClarification: true))
        }
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    @MainActor
    func testPermissionPollKeepsMainActorResponsiveAndCoalesces() async throws {
        let state = Mutex((reads: 0, onMain: false))
        let entered = expectation(description: "status reader entered")
        entered.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let delivered = expectation(description: "status applied")
        let monitor = PermissionStatusMonitor {
            state.withLock { value in value.reads += 1; value.onMain = Thread.isMainThread }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return [.camera]
        }
        monitor.refresh { missing in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(missing, [.camera])
            delivered.fulfill()
        }
        monitor.refresh { _ in XCTFail("A second polling task must not start") }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertFalse(state.withLock { $0.onMain })
        XCTAssertEqual(state.withLock { $0.reads }, 1)
        XCTAssertTrue(monitor.isRefreshing)
        release.signal()
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    func testPermissionPollInvalidationRejectsOlderGrantAndCanRefreshAgain() async throws {
        let entered = expectation(description: "old status read entered")
        let reads = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = PermissionStatusMonitor {
            let ordinal = reads.withLock { value in value += 1; return value }
            if ordinal == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
                return []
            }
            return [.microphone]
        }
        monitor.refresh { _ in XCTFail("Invalidated grant must not replace a newer explicit status") }
        await fulfillment(of: [entered], timeout: 1)
        monitor.invalidate()
        monitor.refresh { _ in XCTFail("Invalidating must not overlap a still-running system read") }
        XCTAssertTrue(monitor.isRefreshing)
        release.signal()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.isRefreshing, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(monitor.isRefreshing)
        let delivered = expectation(description: "new revocation applied")
        monitor.refresh {
            XCTAssertEqual($0, [.microphone])
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    @MainActor
    func testStoppedPermissionPollCannotDeliverOrRestart() async throws {
        let entered = expectation(description: "read entered before shutdown")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let monitor = PermissionStatusMonitor {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return []
        }
        monitor.refresh { _ in XCTFail("Shutdown must discard the outstanding status") }
        await fulfillment(of: [entered], timeout: 1)
        monitor.stop()
        release.signal()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.isRefreshing, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(monitor.isRefreshing)
        monitor.refresh { _ in XCTFail("A stopped poller must not wake capture") }
        XCTAssertFalse(monitor.isRefreshing)
    }

    @MainActor
    private final class PermissionCapture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var onReadiness: ((SpeechReadiness) -> Void)?
        var prepares = 0
        var suspends = 0
        var cancels = 0
        var prepareGate: CheckedContinuation<Void, Never>?
        var holdPreparation = false

        func prepare(inputUID: String?) async throws -> String {
            prepares += 1
            if holdPreparation { await withCheckedContinuation { prepareGate = $0 } }
            try Task.checkCancellation()
            onReadiness?(.ready("permission fixture"))
            return "permission fixture"
        }
        func suspend() async {
            suspends += 1
            prepareGate?.resume()
            prepareGate = nil
        }
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
            XCTFail("Permission polling must not start a voice hold")
            return "permission fixture"
        }
        func finish() {}
        func cancel() { cancels += 1 }
    }

    @MainActor
    func testAlreadyDeniedMicrophoneStatusDoesNotCancelUnrelatedInput() async throws {
        let capture = PermissionCapture()
        let config = Config(defaults: UserDefaults(suiteName: "c1-denied-permission-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        let controller = VoiceController.inert(config: config, speech: capture,
            permissionStatusReader: { [.microphone, .camera] })
        controller.missingPermissions = [.microphone]
        let before = capture.cancels
        controller.refreshPermissionsInBackground(canPrepareMicrophone: { true }) {
            XCTFail("An unchanged denied permission cannot wake the microphone")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !controller.missingPermissions.contains(.camera),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(controller.missingPermissions.contains(.camera))
        XCTAssertEqual(capture.cancels, before)
        XCTAssertEqual(capture.suspends, 0)
        await controller.shutdown()
    }

    @MainActor
    func testPolledRevocationStopsPreparationAndGrantResumesOnceWhenActive() async throws {
        let status = Mutex<[Permission]>([])
        let reads = Mutex(0)
        let capture = PermissionCapture()
        capture.holdPreparation = true
        let config = Config(defaults: UserDefaults(suiteName: "c1-permission-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        let controller = VoiceController.inert(config: config, speech: capture,
            permissionStatusReader: {
                reads.withLock { $0 += 1 }
                return status.withLock { $0 }
            })
        controller.missingPermissions = []
        controller.prepareMicrophone()
        var deadline = ProcessInfo.processInfo.systemUptime + 1
        while capture.prepareGate == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(capture.prepareGate)
        status.withLock { $0 = [.microphone] }
        var grants = 0
        var active = true
        func poll() {
            controller.refreshPermissionsInBackground(canPrepareMicrophone: { active }) {
                grants += 1
                controller.prepareMicrophone()
            }
        }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while capture.suspends == 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(capture.suspends, 0)
        XCTAssertFalse(controller.microphoneReady)
        XCTAssertTrue(controller.missingPermissions.contains(.microphone))
        capture.holdPreparation = false
        status.withLock { $0 = [] }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while !controller.microphoneReady, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(controller.microphoneReady)
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(capture.prepares, 2)
        let previous = reads.withLock { $0 }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while reads.withLock({ $0 }) == previous, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(reads.withLock { $0 }, 3)
        active = false
        controller.suspendMicrophone("Session inactive")
        status.withLock { $0 = [.microphone] }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while !controller.missingPermissions.contains(.microphone),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        status.withLock { $0 = [] }
        poll()
        deadline = ProcessInfo.processInfo.systemUptime + 1
        while controller.missingPermissions.contains(.microphone),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.microphoneReady)
        XCTAssertEqual(grants, 1)
        XCTAssertEqual(capture.prepares, 2)
        await controller.shutdown()
    }
}

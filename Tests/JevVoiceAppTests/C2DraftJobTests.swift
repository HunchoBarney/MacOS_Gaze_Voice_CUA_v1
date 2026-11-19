import Foundation
import Testing
import JevVoiceCore
@testable import JevVoice

struct C2DraftJobTests {
    private typealias Job = C2DraftJob

    @Test func approvalRequiresIndependentPersistence() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let writer = FileWriter(root: store.root)
        let job = makeJob(write: { try writer.write($0) }, reopen: { location in
            try FileReader(root: store.root).open(location)
        })

        #expect(try FileReader(root: store.root).open(job.location) == nil)
        #expect(await job.answer(job.ask, with: .approve) == .done)
        let saved = try #require(try FileReader(root: store.root).open(job.location))
        #expect(saved.taskID == job.ask.taskID)
        #expect(saved.location == job.location)
        #expect(saved.content == job.content)
        #expect(await job.answer(job.ask, with: .approve) == nil)
        let reopened = try #require(try FileReader(root: store.root).open(job.location))
        #expect(reopened.attemptID == saved.attemptID)
    }

    @Test func wrongStaleAndDeclinedAsksDoNotWrite() async {
        let write: Job.Writer = { _ in Issue.record("Unexpected write") }
        let reopen: Job.Reopener = { _ in
            Issue.record("Unexpected reopen")
            return nil
        }
        let job = makeJob(write: write, reopen: reopen)
        let stale = makeJob(deadline: ContinuousClock.now - .seconds(1), write: write, reopen: reopen)
        #expect(job.ask.taskID != stale.ask.taskID)
        #expect(job.ask.askID != stale.ask.askID)

        let wrongAsk = Job.Ask(taskID: job.ask.taskID, askID: UUID(), deadline: job.ask.deadline)
        let wrongTask = Job.Ask(taskID: UUID(), askID: job.ask.askID, deadline: job.ask.deadline)
        #expect(await job.answer(stale.ask, with: .approve) == nil)
        #expect(await job.answer(wrongAsk, with: .approve) == nil)
        #expect(await job.answer(wrongTask, with: .decline) == nil)
        #expect(job.outcome == nil)
        #expect(await stale.answer(stale.ask, with: .approve) == nil)
        #expect(await stale.answer(stale.ask, with: .decline) == nil)
        #expect(stale.outcome == nil)
        #expect(await job.answer(job.ask, with: .decline) == .declined)
        #expect(await job.answer(job.ask, with: .approve) == nil)
        #expect(await job.answer(job.ask, with: .decline) == nil)
        #expect(job.outcome == .declined)
    }

    enum DamagedField: CaseIterable, Sendable {
        case task, target, draft, attempt, recipient, subject, body
    }

    @Test(arguments: DamagedField.allCases)
    func persistedEvidenceMustMatchEveryIdentityAndUTF8Field(field: DamagedField) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let writer = FileWriter(root: store.root)
        let job = makeJob(write: { draft in
            let equivalent = "cafe\u{301}"
            let saved = Job.Draft(
                taskID: field == .task ? UUID() : draft.taskID,
                attemptID: field == .attempt ? UUID() : draft.attemptID,
                location: Job.Location(
                    targetID: field == .target ? UUID() : draft.location.targetID,
                    draftID: field == .draft ? UUID() : draft.location.draftID
                ),
                content: Job.Content(
                    recipient: field == .recipient ? "\(equivalent)@example.invalid" : draft.content.recipient,
                    subject: field == .subject ? equivalent : draft.content.subject,
                    body: field == .body ? "\(equivalent)\n— draft only ✉️" : draft.content.body
                )
            )
            try writer.write(saved, at: draft.location)
        }, reopen: { location in
            try FileReader(root: store.root).open(location)
        })

        let expected: Job.Outcome.Failure = switch field {
        case .task, .target, .draft, .attempt: .identityMismatch
        case .recipient, .subject, .body: .contentMismatch
        }
        #expect(await job.answer(job.ask, with: .approve) == .unverified(expected))
    }

    @Test func writerSuccessWithoutAReopenedDraftIsNotDone() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let job = makeJob(write: { _ in }, reopen: { location in
            try FileReader(root: store.root).open(location)
        })

        #expect(await job.answer(job.ask, with: .approve) == .unverified(.missingDraft))
        #expect(await job.answer(job.ask, with: .approve) == nil)
    }

    @Test func staleSameContentFromTheSameLocationIsNotDone() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let job = makeJob(write: { _ in }, reopen: { location in
            try FileReader(root: store.root).open(location)
        })
        let prior = Job.Draft(taskID: job.ask.taskID, attemptID: UUID(),
                              location: job.location, content: job.content)
        try FileWriter(root: store.root).write(prior)

        #expect(await job.answer(job.ask, with: .approve) == .unverified(.identityMismatch))
    }

    @Test func unreadableFileDoesNotProveADraft() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let job = makeJob(write: { draft in
            try Data("not JSON".utf8).write(to: draftURL(in: store.root, at: draft.location))
        }, reopen: { location in
            try FileReader(root: store.root).open(location)
        })

        #expect(await job.answer(job.ask, with: .approve) == .unverified(.readFailed))
    }

    @Test func writerFailureAfterPersistenceDoesNotClaimRollbackOrRetry() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let writer = FileWriter(root: store.root)
        let job = makeJob(write: { draft in
            try writer.write(draft)
            throw CocoaError(.fileWriteUnknown)
        }, reopen: { _ in
            Issue.record("Unexpected reopen after write failure")
            return nil
        })

        #expect(await job.answer(job.ask, with: .approve) == .unverified(.writeFailed))
        #expect(await job.answer(job.ask, with: .approve) == nil)
        #expect(try FileReader(root: store.root).open(job.location)?.content == job.content)
    }

    @Test func cancellationBeforeDispatchPreventsWrites() async {
        let write: Job.Writer = { _ in Issue.record("Unexpected write after cancellation") }
        let reopen: Job.Reopener = { _ in
            Issue.record("Unexpected reopen after cancellation")
            return nil
        }
        let beforeApproval = makeJob(write: write, reopen: reopen)
        beforeApproval.cancel()
        #expect(await beforeApproval.answer(beforeApproval.ask, with: .approve) == nil)
        #expect(beforeApproval.outcome == .cancelledBeforeDispatch)

        let job = makeJob(write: write, reopen: reopen)
        let gate = SuspensionGate()
        let approval = Task {
            await gate.suspend()
            return await job.answer(job.ask, with: .approve)
        }
        await gate.waitUntilSuspended()
        approval.cancel()
        await gate.release()
        #expect(await approval.value == .cancelledBeforeDispatch)
        await job.waitForWorkerToFinish()
        #expect(await job.answer(job.ask, with: .approve) == nil)
        #expect(job.outcome == .cancelledBeforeDispatch)
    }

    @Test func suspendedWriterDoesNotBlockAnotherJobOrMainActor() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let writer = FileWriter(root: store.root)
        let suspension = SuspensionGate()
        let jobA = makeJob(write: { draft in
            await suspension.suspend()
            try writer.write(draft)
        }, reopen: { _ in
            Issue.record("Reopened a draft after interrupted write returned")
            return nil
        })
        let jobB = makeJob(targetID: jobA.location.targetID, write: { try writer.write($0) }, reopen: { location in
            try FileReader(root: store.root).open(location)
        })
        let approval = Task { await jobA.answer(jobA.ask, with: .approve) }
        await suspension.waitUntilSuspended()

        let probe = await MainActor.run { ForegroundProbe() }
        await probe.tick()
        #expect(await probe.ticks == 1)
        #expect(jobA.outcome == nil)
        #expect(await jobA.answer(jobA.ask, with: .approve) == nil)
        #expect(await jobB.answer(jobB.ask, with: .approve) == .done)
        #expect(jobA.outcome == nil)

        approval.cancel()
        #expect(await approval.value == .interruptedUnverified)
        #expect(jobA.outcome == .interruptedUnverified)
        #expect(try FileReader(root: store.root).open(jobA.location) == nil)
        await suspension.release()
        await jobA.waitForWorkerToFinish()
        #expect(try FileReader(root: store.root).open(jobA.location)?.content == jobA.content)
        #expect(await jobA.answer(jobA.ask, with: .approve) == nil)
        #expect(jobA.outcome == .interruptedUnverified)
        #expect(jobB.outcome == .done)
    }

    @Test func lateMatchingReopenCannotOverwriteInterruption() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let writer = FileWriter(root: store.root)
        let suspension = SuspensionGate()
        let job = makeJob(write: { try writer.write($0) }, reopen: { location in
            let saved = try FileReader(root: store.root).open(location)
            await suspension.suspend()
            return saved
        })
        let approval = Task { await job.answer(job.ask, with: .approve) }
        await suspension.waitUntilSuspended()
        #expect(try FileReader(root: store.root).open(job.location)?.content == job.content)

        job.cancel()
        #expect(await approval.value == .interruptedUnverified)
        await suspension.release()
        await job.waitForWorkerToFinish()
        #expect(job.outcome == .interruptedUnverified)
    }

    private func makeJob(targetID: UUID = UUID(),
                         deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(60),
                         write: @escaping Job.Writer, reopen: @escaping Job.Reopener) -> Job {
        Job(
            targetID: targetID,
            content: .init(recipient: "café@example.invalid", subject: "café", body: "café\n— draft only ✉️"),
            approvalDeadline: deadline,
            write: write,
            reopen: reopen
        )
    }
}

#if DEBUG
@Suite(.serialized) @MainActor
struct C2DraftVoiceFixtureTests {
    enum Scenario: CaseIterable, Sendable { case saved, unavailable, malformed, changedAsk, sendInstead, badReadback, cancelAfterSave, cancelWork, lostConnection }
    private struct Keys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    @Test(arguments: [true, false], Scenario.allCases)
    func onlyOwnedRequestThenExactApprovalCanSave(manual: Bool, scenario: Scenario) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let config = Config(defaults: UserDefaults(suiteName: UUID().uuidString)!, keyStore: Keys(), openAIKeyStore: Keys(), environment: [:])
        config.sounds = false
        let cua = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay(presentsPanels: false), resolver: AppResolver(listApps: { [] }),
            commandDriver: { _, _ in Issue.record("Unexpected driver"); throw CancellationError() }, observeAgents: false)
        defer { cua.shutdown() }
        let target = UUID()
        let content = C2DraftJob.Content(recipient: "alex@example.invalid", subject: "Cedar", body: "Keep the final word maple.")
        let request = "Draft for " + content.recipient + ", subject " + content.subject + ", body " + content.body
        var job: C2DraftJob?, requestTurn: UUID?, requestInput: VoiceRealtimeInput?, openedAsk: VoiceAdmissionContext.Ask?
        var work: VoiceTaskCoordinator.Work?, approvalCurrent: (@MainActor () -> Bool)?
        let writes = LockedBox(0), reads = LockedBox(0)
        let readGate = SuspensionGate()
        func context() -> VoiceAdmissionContext {
            var context = VoiceAdmissionContext()
            context.targetID = target.uuidString
            context.currentAsks = VoiceController.pendingVoiceAsks(in: cua.tasks)
            context.capturedAsks = context.currentAsks
            return context
        }
        func until(_ ready: () async -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(4)
            while !(await ready()) {
                guard ContinuousClock.now < end else { throw VoiceError("Timed out in C2 voice fixture") }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let handle: LocalSpeechSession.FixtureFinal = { admission, onset, final, current in
            guard current(), let input = admission.realtimeInput, onset.targetID == target.uuidString,
                  final.targetID == onset.targetID, context().targetID == onset.targetID else { return false }
            if job == nil {
                guard admission.text.utf8.elementsEqual(request.utf8), onset.capturedAsks.isEmpty,
                      final.currentAsks.isEmpty, context().currentAsks.isEmpty else { return false }
                let row = VoiceTaskCoordinator.Work(label: "Disposable draft", request: request, spec: DriveTask(goal: request))
                row.captureID = admission.turn.id
                work = row
                cua.tasks.append(row)
                requestTurn = admission.turn.id; requestInput = input
                row.worker = Task {
                    let decision = await cua.park(.confirm("Save the disposable fixture draft?"), on: row)
                    guard let job, decision == "yes", !Task.isCancelled, row.active, approvalCurrent?() == true
                    else { job?.cancel(); return }
                    _ = await job.answer(job.ask, with: .approve)
                }
                do { try await until { row.awaitingApproval } } catch { cua.cancel(row.id); return false }
                guard current(), let ask = context().currentAsks.first, ask.kind == .confirm, ask.taskID == row.id,
                      ask.askID == row.askID, context().currentAsks.count == 1 else { cua.cancel(row.id); return false }
                openedAsk = ask
                let draft = C2DraftJob(targetID: target, content: content, approvalDeadline: .now + .seconds(30),
                    taskID: ask.taskID, askID: ask.askID,
                    write: { record in
                        writes.set(writes.value + 1)
                        try FileWriter(root: store.root).write(record)
                    }, reopen: { location in
                        reads.set(reads.value + 1)
                        let record = try FileReader(root: store.root).open(location)
                        if [.cancelAfterSave, .cancelWork].contains(scenario) { await readGate.suspend() }
                        return scenario == .badReadback ? nil : record
                    })
                job = draft
                return true
            }
            guard let job, let work, let worker = work.worker, let openedAsk, requestTurn != admission.turn.id, requestInput != input,
                  admission.route == .local, admission.intent == "respond", admission.text == "Approve.",
                  admission.replyTo == .init(taskID: work.id, askID: openedAsk.askID),
                  admission.slots["task_id"] == work.id.uuidString, admission.slots["ask_id"] == openedAsk.askID.uuidString,
                  VoiceAdmissionContext.Ask.sameParkedSnapshot([openedAsk], onset.capturedAsks),
                  VoiceAdmissionContext.Ask.sameParkedSnapshot([openedAsk], final.currentAsks),
                  VoiceAdmissionContext.Ask.sameParkedSnapshot([openedAsk], context().currentAsks),
                  job.ask.taskID == work.id, job.ask.askID == openedAsk.askID,
                  work.awaitingApproval, current(), ContinuousClock.now < job.ask.deadline else { return false }
            approvalCurrent = current
            _ = await cua.respondToTaskExact(admission.text, taskID: work.id, askID: openedAsk.askID, captureID: admission.turn.id)
            await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            return job.outcome != nil
        }

        let wireA = RecordedVoiceWire(), wireB = RecordedVoiceWire(), count = LockedBox(0)
        let client = RealtimeVoiceClient(wireFactory: { _ in
            let n = count.value; count.set(n + 1)
            return n == 0 ? wireA : wireB
        })
        let manualOwner = LocalSpeechSession(reservedFixtureFinal: scenario == .unavailable ? nil : handle)
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client, admissionOwner: manualOwner)
        defer { lane.cancel(); lane.stopConversation(); client.teardown(); job?.cancel() }
        var latestOwner: LocalSpeechSession?, begins = 0
        lane.conversation.makeSpeechSession = { ctx in
            let owner = LocalSpeechSession(reservedFixtureFinal: scenario == .unavailable ? nil : handle)
            owner.context = ctx; latestOwner = owner
            return owner
        }
        lane.conversation.readContext = context
        lane.conversation.onEvent = {
            if case .began = $0 { begins += 1 }
            if case .final = $0, scenario == .lostConnection, begins == 2 { client.teardown() }
        }
        lane.conversation.onControl = { _ in Issue.record("Unexpected control") }
        lane.conversation.interpret = { _, _, _ in Issue.record("Unexpected interpretation"); return .init(kind: .ignore) }
        lane.conversation.execute = { _ in Issue.record("Unexpected executor"); throw CancellationError() }
        lane.commandHandler = { _, _, _, _, _, _ in Issue.record("Unexpected generic command"); return "{}" }
        lane.exactTaskResponseHandler = { _, _, _, _ in Issue.record("Unexpected generic approval"); return "{}" }
        lane.semanticEnabled = { Issue.record("Unexpected semantic route"); return false }
        lane.contextProvider = { Issue.record("Unexpected provider context"); return "" }
        lane.screenShotProvider = { Issue.record("Unexpected screenshot"); return nil }
        try await lane.prepareRealtimeTransport(manual ? .manual : .conversation)
        if !manual { try lane.beginRealtimeConversation(session: UUID()) }

        func speak(_ text: String, index: Int) async throws {
            let wire = manual && index == 1 ? wireB : wireA
            let item = manual ? await wire.audioItemID() : "spoken-\(index)"
            var finish: Task<Void, Error>?
            if manual {
                if index == 1 { client.teardown(); try await lane.prepareRealtimeTransport(.manual) }
                let token = try lane.beginRemoteManualInput(id: UUID(), mode: .command, context: context(), at: 0)
                finish = Task {
                    let value = try #require(try await lane.finalizeRemoteManualInput(token))
                    if scenario == .lostConnection && index == 1 { client.teardown() }
                    await lane.completeRemoteManualAdmission(value)
                    await lane.completeRemoteManualAdmission(value)
                }
                try await until { await wire.frames().contains { $0["type"]?.string == "input_audio_buffer.commit" } }
            } else {
                for event in ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed"] {
                    try await wire.push(["type": .string(event), "item_id": .string(item)])
                }
                try await until { begins == index + 1 }
            }
            if scenario == .changedAsk, index == 1, let work {
                work.ask = .confirm("Replacement question")
                manualOwner.context = context()
            }
            let completed = "conversation.item.input_audio_transcription.completed"
            try await wire.push(["type": .string("conversation.item.input_audio_transcription.delta"), "item_id": .string(item), "delta": .string("Approve.")])
            try await wire.push(["type": .string(completed), "item_id": .string("foreign"), "transcript": .string("Approve.")])
            let final: [String: JSONValue] = ["type": .string(completed), "item_id": .string(item), "transcript": .string(text)]
            try await wire.push(final); try await wire.push(final)
            if [.cancelAfterSave, .cancelWork].contains(scenario), index == 1 {
                try await until { await readGate.isWaiting }
                if scenario == .cancelWork, let work { cua.cancel(work.id) } else { lane.cancel() }
                await readGate.release()
            }
            if let finish { try await finish.value }
            let owner = manual ? manualOwner : try #require(latestOwner)
            try await until { [.completed, .failed, .cancelled].contains(owner.gate.state) }
            if scenario == .unavailable { #expect(owner.gate.failureReason == "fixture_unavailable") }
            if scenario == .lostConnection && index == 1 { #expect(owner.gate.state == .cancelled) }
            if scenario == .malformed || (index == 1 && [.sendInstead, .changedAsk].contains(scenario)) {
                try await until { owner.gate.failureReason == "fixture_refused" }
            }
        }
        try await speak(scenario == .malformed ? "Draft for alex@example.invalid" : request, index: 0)
        #expect(writes.value == 0 && reads.value == 0)
        if scenario == .unavailable || scenario == .malformed {
            #expect(job == nil && cua.tasks.isEmpty)
        } else {
            try await until { job != nil && work?.awaitingApproval == true }
            #expect(openedAsk?.kind == .confirm && cua.tasks.count == 1)
            try await speak(scenario == .sendInstead ? "Send it." : "Approve.", index: 1)
            let draft = try #require(job)
            if [.saved, .badReadback, .cancelAfterSave, .cancelWork].contains(scenario) {
                try await until { draft.outcome != nil }
                await draft.waitForWorkerToFinish()
                let expected: C2DraftJob.Outcome = [.cancelAfterSave, .cancelWork].contains(scenario) ? .interruptedUnverified
                    : scenario == .saved ? .done : .unverified(.missingDraft)
                #expect(draft.outcome == expected)
                #expect(writes.value == 1 && reads.value == 1)
                let saved = try #require(try FileReader(root: store.root).open(draft.location))
                #expect(saved.taskID == work?.id && saved.taskID == draft.ask.taskID)
                #expect(saved.location.targetID == target && saved.content == content)
            } else {
                #expect(draft.outcome == nil && writes.value == 0 && reads.value == 0)
                #expect(work?.awaitingAnswer == true)
            }
        }
        let frames = await wireA.frames() + wireB.frames()
        #expect(!frames.contains { ["response.create", "conversation.item.create"].contains($0["type"]?.string) })
        if let work { cua.cancel(work.id) }
        await work?.worker?.value
    }
}
#endif

private struct TemporaryStore: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FileWriter: Sendable {
    let root: URL

    func write(_ draft: C2DraftJob.Draft) throws {
        try write(draft, at: draft.location)
    }

    func write(_ draft: C2DraftJob.Draft, at location: C2DraftJob.Location) throws {
        try JSONEncoder().encode(draft).write(to: draftURL(in: root, at: location), options: .atomic)
    }
}

private struct FileReader: Sendable {
    let root: URL

    func open(_ location: C2DraftJob.Location) throws -> C2DraftJob.Draft? {
        do {
            let bytes = try Data(contentsOf: draftURL(in: root, at: location))
            return try JSONDecoder().decode(C2DraftJob.Draft.self, from: bytes)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}

private func draftURL(in root: URL, at location: C2DraftJob.Location) -> URL {
    root.appendingPathComponent("\(location.targetID.uuidString)-\(location.draftID.uuidString).json")
}

private actor SuspensionGate {
    private var operation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { operation != nil }

    func suspend() async {
        await withCheckedContinuation {
            operation = $0
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard operation == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        operation?.resume()
        operation = nil
    }
}

@MainActor private final class ForegroundProbe {
    private(set) var ticks = 0

    func tick() {
        ticks += 1
    }
}

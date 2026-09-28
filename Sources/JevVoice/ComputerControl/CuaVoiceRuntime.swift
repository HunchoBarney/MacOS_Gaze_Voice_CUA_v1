import Foundation
import JevVoiceCore

@MainActor
final class CuaVoiceRuntime {
    private static let observationTools: Set<String> = [
        "list_apps", "get_accessibility_tree", "list_windows", "get_window_state",
        "get_browser_state", "parse_visual_regions"
    ]

    private static func dispatchesEffect(tool: String, arguments: [String: JSONValue]) -> Bool {
        if observationTools.contains(tool) { return false }
        return tool != "browser_dialog" || arguments["action"] != .string("inspect")
    }

    final class Work: Identifiable {
        let id = UUID()
        let label: String
        let request: String
        var status = "Queued"
        var message = ""
        var bundle: String?
        var window: Int?
        var launchReceipt: CuaLaunchReceipt?
        var dispatchedEffect = false
        var provenance: SpeechProvenance?
        var worker: Task<Void, Never>?
        var elapsedMs: Double = 0
        var timings: [String: Double] = [:]
        var active = true
        var approval: String?
        var approvalContinuation: CheckedContinuation<Bool, Never>?
        init(label: String, request: String) { self.label = label; self.request = request }
    }

    private final class Invocation {
        var work: Work?
        var timings: [String: Double] = [:]
        let receivedAt: Double
        init(receivedAt: Double) { self.receivedAt = receivedAt }
    }

    private let config: Config
    private let judge: CuaTaskAgent.Judge
    private let requiresAPIKey: Bool
    private let makeConnection: () -> CuaConnection
    private let queue = CuaWorkQueue()
    private let appInventory = CuaAppInventory()
    private(set) var tasks: [Work] = []
    private(set) var selectedID: UUID?
    private var initialApp = ""
    private var nextLabel = 0
    private let instanceLabel = String(UUID().uuidString.prefix(6))
    var onChange: () -> Void = {}

    lazy var speech: ContinuousIntentCoordinator = {
        let coordinator = ContinuousIntentCoordinator(submit: { [weak self] handoff in
            guard let self else { throw CancellationError() }
            try await self.receive(handoff)
        })
        coordinator.context = { [weak self] in self?.context ?? .object([:]) }
        coordinator.onChange = { [weak self] in self?.onChange() }
        return coordinator
    }()

    init(config: Config, makeConnection: @escaping () -> CuaConnection = { CuaConnection() }, judge: CuaTaskAgent.Judge? = nil) {
        self.config = config
        self.makeConnection = makeConnection
        if let judge {
            self.judge = judge
            self.requiresAPIKey = false
        } else {
            self.requiresAPIKey = true
            self.judge = { state, questions in
                try await JevClient(apiKey: config.apiKey).systemOne(state: state, questions: questions).response.answers
            }
        }
    }

    var active: Bool { tasks.contains(where: \.active) || speech.busy }
    var message: String {
        if !speech.message.isEmpty,
           ["incomplete", "clarification", "dictationWaitingForFinal"].contains(speech.outcome) {
            return speech.message
        }
        return tasks.first(where: { $0.id == selectedID })?.message ?? speech.message
    }
    var context: JSONValue {
        .object(["initial_app": .string(initialApp), "tasks": .array(tasks.suffix(12).map {
            .object(["id": .string($0.id.uuidString), "label": .string($0.label), "request": .string($0.request),
                     "status": .string($0.status), "app": .string($0.bundle ?? ""), "result": .string($0.message)])
        })])
    }

    func begin(app: String?, captureID: UUID = UUID()) {
        initialApp = app ?? ""
        selectedID = nil
        speech.begin(captureID: captureID)
    }
    func update(_ text: String, final: Bool) { speech.update(text, final: final); onChange() }
    func cancelCapture() { speech.cancel() }
    func cancelSelected() { if let id = selectedID { cancel(id) } }
    func cancel(_ id: UUID) {
        guard let work = tasks.first(where: { $0.id == id }), work.active, work.status != "Stopping" else { return }
        resolveApproval(id, approved: false)
        work.status = "Stopping"
        work.message = "Stopping; already dispatched effects may finish."
        work.worker?.cancel()
        onChange()
    }
    func stopAll() {
        speech.cancel()
        for work in tasks where work.active { cancel(work.id) }
        onChange()
    }
    func resolveApproval(_ id: UUID, approved: Bool) {
        guard let work = tasks.first(where: { $0.id == id }), let continuation = work.approvalContinuation else { return }
        work.approvalContinuation = nil
        work.approval = nil
        continuation.resume(returning: approved)
        onChange()
    }
    private func requestApproval(_ description: String, for work: Work) async throws -> Bool {
        try Task.checkCancellation()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.approval = description
                work.approvalContinuation = continuation
                work.status = "Needs confirmation"
                work.message = description
                selectedID = work.id
                onChange()
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(work.id, approved: false) }
        }
        try Task.checkCancellation()
        if accepted { work.status = "Working"; onChange() }
        return accepted
    }
    func select(_ id: UUID) { selectedID = id; onChange() }
    func shutdown() async {
        let pendingDecision = speech.cancel()
        for work in tasks where work.active { cancel(work.id) }
        onChange()
        await pendingDecision?.value
        for work in tasks { await work.worker?.value }
    }

    private func receive(_ handoff: TranscriptHandoff) async throws {
        if requiresAPIKey, config.apiKey.isEmpty {
            throw DriverConnectionError.refused("Save the Jev API key in Commands settings.")
        }
        nextLabel += 1
        let label = "Jarvis \(nextLabel) · \(instanceLabel)"
        let connection = makeConnection()
        let invocation = Invocation(receivedAt: handoff.receivedAt)
        let agent = makeAgent(connection: connection, label: label, invocation: invocation)
        do {
            let previousContext = handoff.taskContext["initial_app"]?.string ?? initialApp
            let decision: CuaExecutorDecision
            if let cachedInventory = appInventory.snapshot() {
                let cachedDecision = try await agent.decide(handoff: handoff,
                    previousContext: previousContext, installedApps: cachedInventory)
                if cachedDecision.operation == .execute ||
                    (cachedDecision.operation == .clarify && cachedDecision.clarification == .target) {
                    try await startSession(connection, label: label)
                    let currentInventory = try await makeToolCall(connection: connection, label: label,
                        invocation: invocation)("list_apps", [:])
                    decision = currentInventory == cachedInventory ? cachedDecision :
                        try await agent.decide(handoff: handoff, previousContext: previousContext,
                            installedApps: currentInventory)
                } else {
                    decision = cachedDecision
                }
            } else {
                try await startSession(connection, label: label)
                let inventory = try await makeToolCall(connection: connection, label: label,
                    invocation: invocation)("list_apps", [:])
                decision = try await agent.decide(handoff: handoff,
                    previousContext: previousContext, installedApps: inventory)
            }
            invocation.timings["Transcript to first Jev decision"] =
                (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
            try Task.checkCancellation()

            switch decision.operation {
            case .wait:
                speech.report(handoff, outcome: "incomplete", message: handoff.final ? "The request is incomplete; no action was taken." : "Listening for a complete request…")
                await finishSession(connection, label: label)
            case .clarify:
                speech.report(handoff, outcome: "clarification",
                              message: decision.clarification?.question ?? "What would you like me to do?")
                await finishSession(connection, label: label)
            case .ignore:
                if let range = decision.consumedRange { _ = speech.consume(handoff, wordRange: range) }
                await finishSession(connection, label: label)
            case .stopAll:
                guard let range = decision.consumedRange, speech.consume(handoff, wordRange: range) else {
                    await finishSession(connection, label: label)
                    return
                }
                stopAll()
                await finishSession(connection, label: label)
            case .execute, .stop, .correction:
                guard let range = decision.consumedRange, let source = decision.request else {
                    await finishSession(connection, label: label)
                    throw DriverConnectionError.malformed
                }
                if decision.contentMode != .control, !handoff.final {
                    let message = decision.contentMode == .dictate
                        ? "Dictation will be inserted after you finish speaking."
                        : "Text will be inserted after you finish speaking."
                    speech.report(handoff, outcome: "dictationWaitingForFinal", message: message)
                    await finishSession(connection, label: label)
                    return
                }
                let provenance = handoff.provenance(for: range)
                let previousSelection = selectedID
                let request = source
                let work = createWork(label: label, request: request, provenance: provenance, invocation: invocation)
                guard speech.consume(handoff, wordRange: range) else {
                    tasks.removeAll { $0.id == work.id }
                    selectedID = previousSelection
                    await finishSession(connection, label: label)
                    return
                }
                work.worker = Task { [weak self] in
                    guard let self else { await connection.close(); return }
                    await self.runSelected(decision, handoff: handoff, work: work, agent: agent,
                                           connection: connection, label: label, invocation: invocation)
                }
            }
        } catch {
            await finishSession(connection, label: label)
            throw error
        }
    }

    private func createWork(label: String, request: String, provenance: SpeechProvenance, invocation: Invocation) -> Work {
        let work = Work(label: label, request: request)
        work.provenance = provenance
        work.timings = invocation.timings
        work.timings["Transcript to submission"] = (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
        invocation.work = work
        tasks.append(work)
        selectedID = work.id
        while tasks.count > 32, let index = tasks.firstIndex(where: { !$0.active }) { tasks.remove(at: index) }
        onChange()
        return work
    }

    private func makeAgent(connection: CuaConnection, label: String, invocation: Invocation) -> CuaTaskAgent {
        CuaTaskAgent(call: makeToolCall(connection: connection, label: label, invocation: invocation),
            judge: makeTimedJudge(invocation), generate: { prompt, context, reasoning in
                let accessStarted = ProcessInfo.processInfo.systemUptime
                let client = try {
                    defer { invocation.timings["Provider credential access", default: 0] += (ProcessInfo.processInfo.systemUptime - accessStarted) * 1000 }
                    return try TextProviderSettings.shared.client()
                }()
                let generationStarted = ProcessInfo.processInfo.systemUptime
                defer { invocation.timings["Text generation", default: 0] += (ProcessInfo.processInfo.systemUptime - generationStarted) * 1000 }
                return try await client.generate(prompt: prompt, context: context, reasoning: reasoning)
            }, reasoningAvailable: TextProviderSettings.shared.configured, approve: { [weak self] description in
                guard let self, let work = invocation.work else { return false }
                return try await self.requestApproval(description, for: work)
            })
    }

    private func startSession(_ connection: CuaConnection, label: String) async throws {
        try await connection.connect()
        _ = try await connection.call("start_session", arguments: ["session": .string(label)])
    }

    private func makeTimedJudge(_ invocation: Invocation) -> CuaTaskAgent.Judge {
        { state, questions in
            let started = ProcessInfo.processInfo.systemUptime
            defer { invocation.timings["Jev execution", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
            return try await self.judge(state, questions)
        }
    }

    private func makeToolCall(connection: CuaConnection, label: String, invocation: Invocation,
                              useInstalledAppCache: Bool = true) -> CuaTaskAgent.Call {
        { tool, arguments in
            try Task.checkCancellation()
            if let work = invocation.work,
               Self.dispatchesEffect(tool: tool, arguments: arguments) {
                work.dispatchedEffect = true
                if work.timings["Transcript to first dispatch"] == nil {
                    let elapsed = (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
                    work.timings["Transcript to first dispatch"] = elapsed
                    invocation.timings["Transcript to first dispatch"] = elapsed
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            defer { invocation.timings["Cua \(tool)", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
            let arguments = arguments.merging(["session": .string(label)]) { _, current in current }
            if tool == "list_apps", useInstalledAppCache {
                return try await self.appInventory.read { try await connection.call(tool, arguments: arguments) }
            }
            return try await connection.call(tool, arguments: arguments)
        }
    }

    private func runSelected(_ decision: CuaExecutorDecision, handoff: TranscriptHandoff, work: Work,
                             agent: CuaTaskAgent, connection: CuaConnection, label: String,
                             invocation: Invocation) async {
        let start = ContinuousClock.now
        do {
            switch decision.operation {
            case .stop:
                guard let id = decision.selectedTaskID, let target = tasks.first(where: { $0.id == id }) else {
                    throw DriverConnectionError.refused("The selected task is no longer available to stop.")
                }
                cancel(target.id)
                work.message = target.active ? "Stop requested for \(target.label); in-flight effects may finish." : "The selected task has already completed."
                work.status = "Completed"
            case .correction:
                try await applyCorrection(decision, work: work, agent: agent, connection: connection,
                                          label: label, initialApp: handoff.taskContext["initial_app"]?.string ?? "",
                                          invocation: invocation)
            case .execute:
                try await execute(decision, dependencyID: decision.dependencyTaskID,
                                  initialApp: handoff.taskContext["initial_app"]?.string ?? "", work: work,
                                  agent: agent, invocation: invocation)
            default:
                throw DriverConnectionError.malformed
            }
            try Task.checkCancellation()
            if work.status != "Completed" { work.status = "Completed" }
            work.timings["Transcript to observed result"] = (ProcessInfo.processInfo.systemUptime - handoff.receivedAt) * 1000
        } catch is CancellationError {
            work.status = "Cancelled"
            work.message = "Cancelled. Already dispatched effects may have finished."
        } catch {
            work.status = Task.isCancelled ? "Cancelled" : "Failed"
            work.message = Task.isCancelled ? "Cancelled. Already dispatched effects may have finished." : error.localizedDescription
        }
        await finishSession(connection, label: label)
        for (name, milliseconds) in invocation.timings { work.timings[name] = milliseconds }
        queue.release(work.id)
        let duration = start.duration(to: .now).components
        work.elapsedMs = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        work.active = false
        onChange()
    }

    private func execute(_ decision: CuaExecutorDecision, dependencyID: UUID?, initialApp: String, work: Work,
                         agent: CuaTaskAgent, invocation: Invocation) async throws {
        defer {
            work.bundle = agent.bundleID ?? work.bundle
            work.window = agent.windowID ?? work.window
            work.launchReceipt = agent.launchReceipt ?? work.launchReceipt
        }
        var dependency: Work?
        if let dependencyID {
            guard let selected = tasks.first(where: { $0.id == dependencyID }) else {
                throw DriverConnectionError.refused("The selected related task is no longer available.")
            }
            dependency = selected
            if selected.active {
                work.status = "Waiting"
                work.message = "Waiting for \(selected.label)…"
                onChange()
                await selected.worker?.value
                try Task.checkCancellation()
            }
            guard selected.status == "Completed" else {
                throw DriverConnectionError.refused("The related task did not complete. Nothing dependent was executed.")
            }
        }
        let context = dependency.map { "Previous task: \($0.request). App: \($0.bundle ?? ""). Result: \($0.message)" } ?? initialApp
        work.message = "Starting the selected Cua operation…"
        work.status = "Working"
        onChange()
        work.message = try await agent.execute(decision, context: context, windowID: dependency?.window,
            actionOwner: CuaActionOwner(taskID: work.id, revision: work.provenance?.revision ?? 0),
            acquireApp: { app in
                work.bundle = app
                work.status = "Waiting"
                work.message = "Waiting for \(app)…"
                self.onChange()
                let queued = ProcessInfo.processInfo.systemUptime
                try await self.queue.acquire(work.id, app: app)
                invocation.timings["Queue wait", default: 0] += (ProcessInfo.processInfo.systemUptime - queued) * 1000
                work.status = "Working"
                self.onChange()
            }, progress: { progress in
                work.message = progress
                self.onChange()
            })
    }

    private func applyCorrection(_ decision: CuaExecutorDecision, work: Work, agent: CuaTaskAgent,
                                 connection: CuaConnection, label: String, initialApp: String,
                                 invocation: Invocation) async throws {
        guard let id = decision.selectedTaskID, let target = tasks.first(where: { $0.id == id }), target.id != work.id else {
            throw DriverConnectionError.refused("The selected task is no longer available to correct.")
        }
        if target.active { cancel(target.id) }
        await target.worker?.value
        try Task.checkCancellation()
        var sessionStarted = false
        if let receipt = target.launchReceipt {
            try await startSession(connection, label: label)
            sessionStarted = true
            work.status = "Waiting"
            work.message = "Checking whether the original launch is unchanged…"
            onChange()
            let queued = ProcessInfo.processInfo.systemUptime
            try await queue.acquire(work.id, app: receipt.bundle)
            invocation.timings["Queue wait", default: 0] += (ProcessInfo.processInfo.systemUptime - queued) * 1000
            work.message = try await receipt.reverse(call: makeToolCall(connection: connection, label: label, invocation: invocation,
                useInstalledAppCache: false),
                judge: makeTimedJudge(invocation), approveFocus: {
                    try await self.requestApproval("Temporarily focus \(receipt.bundle) to normally quit the unchanged app launched by \(target.label). No work will be discarded.", for: work)
                })
            queue.release(work.id)
        } else if target.dispatchedEffect {
            throw DriverConnectionError.refused("Pending work stopped. No unchanged launch is eligible for reversal; completed or uncertain effects remain.")
        } else {
            work.message = "The earlier request was cancelled before any computer action was dispatched."
        }

        guard let replacement = decision.replacementExecution else {
            work.status = "Completed"
            return
        }
        if !sessionStarted { try await startSession(connection, label: label) }
        try await execute(replacement, dependencyID: nil, initialApp: initialApp, work: work, agent: agent, invocation: invocation)
    }

    private func finishSession(_ connection: CuaConnection, label: String) async {
        await Task.detached {
            _ = try? await connection.call("end_session", arguments: ["session": .string(label)], timeout: 5)
            await connection.close()
        }.value
    }
}

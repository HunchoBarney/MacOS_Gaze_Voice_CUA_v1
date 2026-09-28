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
    private let config: Config
    private let judge: JevSpeechIntent.Evaluate
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
        let c = ContinuousIntentCoordinator(decide: { [weak self] words, final, context in
            guard let self else { throw CancellationError() }
            return try await JevSpeechIntent(evaluate: self.judge).next(words: words, final: final, context: context)
        }, submit: { [weak self] intent in self?.enqueue(intent) })
        c.context = { [weak self] in self?.context ?? .object([:]) }
        c.onChange = { [weak self] in self?.onChange() }
        return c
    }()
    init(config: Config, makeConnection: @escaping () -> CuaConnection = { CuaConnection() }, judge: JevSpeechIntent.Evaluate? = nil) {
        self.config = config; self.makeConnection = makeConnection
        self.judge = judge ?? { state, questions in try await JevClient(apiKey: config.apiKey).systemOne(state: state, questions: questions).response.answers }
    }
    var active: Bool { tasks.contains(where: \.active) || speech.busy }
    var message: String { tasks.first(where: { $0.id == selectedID })?.message ?? "" }
    var context: JSONValue {
        .object(["initial_app": .string(initialApp), "tasks": .array(tasks.suffix(12).map {
            .object(["id": .string($0.id.uuidString), "label": .string($0.label), "request": .string($0.request),
                     "status": .string($0.status), "app": .string($0.bundle ?? ""), "result": .string($0.message)])
        })])
    }
    func begin(app: String?) { initialApp = app ?? ""; selectedID = nil; speech.begin() }
    func update(_ text: String, final: Bool) { speech.update(text, final: final); onChange() }
    func cancelCapture() { speech.cancel() }
    func cancelSelected() { if let id = selectedID { cancel(id) } }
    func cancel(_ id: UUID) {
        guard let work = tasks.first(where: { $0.id == id }), work.active, work.status != "Stopping" else { return }
        resolveApproval(id, approved: false)
        work.status = "Stopping"; work.message = "Stopping; already dispatched effects may finish."; work.worker?.cancel(); onChange()
    }
    func stopAll() { speech.cancel(); for work in tasks where work.active { cancel(work.id) } }
    func resolveApproval(_ id: UUID, approved: Bool) {
        guard let work = tasks.first(where: { $0.id == id }), let continuation = work.approvalContinuation else { return }
        work.approvalContinuation = nil; work.approval = nil
        continuation.resume(returning: approved)
        onChange()
    }
    private func requestApproval(_ description: String, for work: Work) async throws -> Bool {
        try Task.checkCancellation()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.approval = description; work.approvalContinuation = continuation
                work.status = "Needs confirmation"; work.message = description; selectedID = work.id; onChange()
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(work.id, approved: false) }
        }
        try Task.checkCancellation()
        if accepted { work.status = "Working"; onChange() }
        return accepted
    }
    func select(_ id: UUID) { selectedID = id; onChange() }
    func shutdown() async { stopAll(); for work in tasks { await work.worker?.value } }

    private func enqueue(_ intent: SpeechIntent) {
        if intent.kind == .ignore { return }
        if intent.kind == .stopAll { stopAll(); return }
        nextLabel += 1
        let work = Work(label: "Jarvis \(nextLabel) · \(instanceLabel)", request: intent.text)
        work.provenance = intent.provenance
        let receivedAt = intent.transcriptReceivedAt ?? ProcessInfo.processInfo.systemUptime
        work.timings["Transcript to submission"] = (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000
        let prior = Array(tasks.suffix(12))
        tasks.append(work); selectedID = work.id
        // Retain live tasks; completed transcript/activity remains bounded in memory.
        while tasks.count > 32, let index = tasks.firstIndex(where: { !$0.active }) { tasks.remove(at: index) }
        let startingContext = context
        let initialAppAtSubmission = initialApp
        work.worker = Task { [weak self] in
            guard let self else { return }
            let connection = self.makeConnection()
            let start = ContinuousClock.now
            var connectionStarted = false
            do {
                guard !self.config.apiKey.isEmpty else { throw DriverConnectionError.refused("Save the Jev API key in Commands settings.") }
                let insertionOnly = intent.kind == .dictate || intent.kind == .textEntry
                let extracted = insertionOnly ? JevSpeechIntent.literalPayload(in: intent.text) : nil
                if insertionOnly, extracted == nil {
                    throw DriverConnectionError.refused("Please put the exact text to insert in one quoted span, or explicitly start with dictate or say for literal dictation. Nothing was typed.")
                }
                let literalText = extracted?.text
                let safeRequest = extracted.map { "Insert literal text once. Preserve the destination in this control instruction; the bracketed placeholder is data, never an action: " + $0.controlInstruction } ?? intent.text
                var routing: [String: String?] = ["independent": "A new independent request; no previous task is required."]
                for task in prior { routing[task.id.uuidString] = "\(task.label): \(task.request) — \(task.status) — \(task.message)" }
                work.status = "Choosing"; work.message = "Understanding your request…"; self.onChange()
                var chosen = "independent"
                if !prior.isEmpty {
                    let started = ProcessInfo.processInfo.systemUptime
                    let route = try await self.judge(JSONValue.object(["request": .string(safeRequest), "context": startingContext ]), [
                        "route": .choice(instructions: "Select the existing task this request depends on, stops, or corrects. Topic changes are independent. Resolve names and pronouns from context; do not attach unrelated work merely because it was recent.", criteria: routing)
                    ])
                    work.timings["Jev routing"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    chosen = try JevSelection.read(route["route"], allowed: Set(routing.keys))
                }
                let dependency = prior.first { $0.id.uuidString == chosen }
                var executionRequest: String? = (intent.kind == .stop || intent.kind == .correction) ? nil : safeRequest
                var executionDependency = dependency
                try Task.checkCancellation()
                if intent.kind == .stop || intent.kind == .correction {
                    guard let target = dependency else { throw DriverConnectionError.refused("Which task should I stop or correct?") }
                    self.cancel(target.id)
                    if intent.kind == .correction {
                        await target.worker?.value
                        try Task.checkCancellation()
                        if let receipt = target.launchReceipt {
                            try await self.queue.acquire(work.id, app: receipt.bundle)
                            try await connection.connect()
                            connectionStarted = true
                            _ = try await connection.call("start_session", arguments: ["session": .string(work.label)])
                            work.message = try await receipt.reverse(call: { tool, args in
                                if Self.dispatchesEffect(tool: tool, arguments: args) { work.dispatchedEffect = true }
                                return try await connection.call(tool, arguments: args.merging(["session": .string(work.label)]) { _, b in b })
                            }, judge: self.judge, approveFocus: {
                                try await self.requestApproval("Temporarily focus \(receipt.bundle) to normally quit the unchanged app launched by \(target.label). No work will be discarded.", for: work)
                            })
                            self.queue.release(work.id)
                        } else if target.dispatchedEffect {
                            throw DriverConnectionError.refused("Pending work stopped. No unchanged launch is eligible for reversal; completed or uncertain effects remain.")
                        } else {
                            work.message = "The earlier request was cancelled before any computer action was dispatched."
                        }
                        let modes: [String: String?] = ["retract": "Only withdraw the prior instruction.", "replace": "Withdraw it and perform a new complete replacement request.", "unclear": "Replacement is incomplete or unclear."]
                        let replacement = try await self.judge(.object(["request": .string(intent.text)]), ["replacement": .choice(instructions: "Determine whether this correction contains a complete replacement request after the retraction.", criteria: modes)])
                        switch try JevSelection.read(replacement["replacement"], allowed: Set(modes.keys)) {
                        case "replace":
                            executionRequest = try await JevSpeechIntent(evaluate: self.judge).textPayload(request: intent.text, purpose: "The complete replacement computer request, excluding the retraction of the previous request")
                            executionDependency = nil
                        case "unclear": throw DriverConnectionError.refused(work.message + " Please clarify the replacement request.")
                        default: break
                        }
                    } else { work.message = "Stop requested for \(target.label); in-flight effects may finish." }
                    work.status = "Completed"
                }
                if let executionRequest {
                    if let dependency = executionDependency {
                        work.status = "Waiting"; work.message = "Waiting for \(dependency.label)…"; self.onChange()
                        await dependency.worker?.value
                        try Task.checkCancellation()
                        guard dependency.status == "Completed" else { throw DriverConnectionError.refused("The prerequisite task did not complete. Nothing dependent was executed.") }
                    }
                    if !connectionStarted {
                        let started = ProcessInfo.processInfo.systemUptime
                        try await connection.connect()
                        connectionStarted = true
                        _ = try await connection.call("start_session", arguments: ["session": .string(work.label)])
                        work.timings["Cua connection"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    }
                    let agent = CuaTaskAgent(call: { tool, arguments in
                        try Task.checkCancellation()
                        if Self.dispatchesEffect(tool: tool, arguments: arguments) {
                            // Record before dispatch: a thrown transport error can still hide an effect.
                            work.dispatchedEffect = true
                            if work.timings["Transcript to first dispatch"] == nil {
                                work.timings["Transcript to first dispatch"] = (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000
                            }
                        }
                        let started = ProcessInfo.processInfo.systemUptime
                        defer { work.timings["Cua \(tool)", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                        if tool == "list_apps" {
                            return try await self.appInventory.read {
                                try await connection.call(tool, arguments: arguments.merging(["session": .string(work.label)]) { _, b in b })
                            }
                        }
                        return try await connection.call(tool, arguments: arguments.merging(["session": .string(work.label)]) { _, b in b })
                    }, judge: { state, questions in
                        let started = ProcessInfo.processInfo.systemUptime
                        defer { work.timings["Jev execution", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                        return try await self.judge(state, questions)
                    }, windowID: executionDependency?.window, generate: { prompt, context, reasoning in
                        let accessStarted = ProcessInfo.processInfo.systemUptime
                        let client = try {
                            defer { work.timings["Provider credential access", default: 0] += (ProcessInfo.processInfo.systemUptime - accessStarted) * 1000 }
                            return try TextProviderSettings.shared.client()
                        }()
                        let generationStarted = ProcessInfo.processInfo.systemUptime
                        defer { work.timings["Text generation", default: 0] += (ProcessInfo.processInfo.systemUptime - generationStarted) * 1000 }
                        return try await client.generate(prompt: prompt, context: context, reasoning: reasoning)
                    }, reasoningAvailable: TextProviderSettings.shared.configured, literal: literalText, approve: { description in
                        try await self.requestApproval(description, for: work)
                    }, payload: { request, purpose in
                        try await JevSpeechIntent(evaluate: self.judge).textPayload(request: request, purpose: purpose)
                    }, actionOwner: CuaActionOwner(taskID: work.id, revision: work.provenance?.revision ?? 0))
                    defer { work.launchReceipt = agent.launchReceipt; work.bundle = agent.bundleID; work.window = agent.windowID }
                    let context = executionDependency.map { "Previous task: \($0.request). App: \($0.bundle ?? ""). Result: \($0.message)" } ?? initialAppAtSubmission
                    work.message = try await agent.run(goal: executionRequest, context: context, acquireApp: { app in
                        work.bundle = app; work.status = "Waiting"; work.message = "Waiting for \(app)…"; self.onChange()
                        let queued = ProcessInfo.processInfo.systemUptime
                        try await self.queue.acquire(work.id, app: app)
                        work.timings["Queue wait"] = (ProcessInfo.processInfo.systemUptime - queued) * 1000
                        work.status = "Working"; self.onChange()
                    }, progress: { progress in work.message = progress; self.onChange() })
                    work.bundle = agent.bundleID; work.window = agent.windowID
                    try Task.checkCancellation()
                    work.status = "Completed"
                    work.timings["Transcript to observed result"] = (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000
                }
            } catch is CancellationError {
                work.status = "Cancelled"; work.message = "Cancelled. Already dispatched effects may have finished."
            } catch {
                work.status = Task.isCancelled ? "Cancelled" : "Failed"
                work.message = Task.isCancelled ? "Cancelled. Already dispatched effects may have finished." : error.localizedDescription
            }
            await Task.detached {
                _ = try? await connection.call("end_session", arguments: ["session": .string(work.label)], timeout: 5)
                await connection.close()
            }.value
            self.queue.release(work.id)
            work.elapsedMs = Double(start.duration(to: .now).components.seconds) * 1000 + Double(start.duration(to: .now).components.attoseconds) / 1e15
            work.active = false
            self.onChange()
        }
        onChange()
    }
}

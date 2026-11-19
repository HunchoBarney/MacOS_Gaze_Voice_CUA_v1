import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class VoiceAskProjectionTests: XCTestCase {
    private enum Row: String, CaseIterable {
        case move, unchanged, answer, remote, replacedAsk, ambiguous, swappedWindow, negative
        var text: String {
            switch self {
            case .answer, .replacedAsk, .ambiguous: return "second"
            case .remote: return "Organize the fixture notes"
            case .negative: return "Do not scroll down"
            default: return "scroll down"
            }
        }
    }

    private final class Store {
        var viewport = 0
        var asks: [VoiceAdmissionContext.Ask] = []
        var notes = [2, 1]
        var chosen: String?
        var window = 100
        func observe() -> (viewport: Int, asks: [UUID], notes: [Int]) { (viewport, asks.map(\.askID), notes) }
    }

    private struct Trace: Codable {
        var events: [String: Double] = [:]
        var rawReads: [String] = []
        var captured = ""
        var inputs = 0, routes = 0, actions = 0, judgments = 0, tools = 0, responses = 0
        var terminal = ""
        var task: UUID?, ask: UUID?, turn: UUID?, epoch: UUID?
        var item = "", connection: UUID?
        var virtualMilliseconds = 0
        var virtualAtFinal = 0
    }

    @MainActor private final class Arm {
        let wire = RecordedVoiceWire(), store = Store()
        let lane: RealtimeVoiceLane
        let client: RealtimeVoiceClient
        let projected: Bool
        var row: Row = .move
        var trace = Trace()
        var delay = 0
        var site = "onset"
        let session = UUID()
        var serial = 0
        private let received = LockedBox<[String: Double]>([:])
        let readOrigin = DispatchTime.now().uptimeNanoseconds
        var clock: Double { Double(DispatchTime.now().uptimeNanoseconds - readOrigin) / 1e6 }
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let askID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        init(projected: Bool) {
            self.projected = projected
            let peer = wire
            client = .init(wireFactory: { _ in peer })
            lane = .init(apiKey: { "fixture" }, client: client)
            let forward = client.onWireEvent, origin = readOrigin, received = self.received
            client.onWireEvent = { event in
                if let item = event.inputItemID, event.kind.hasPrefix("input_audio_buffer.")
                    || event.kind == "conversation.item.input_audio_transcription.completed" {
                    var values = received.value
                    values[item + ":" + event.kind] = Double(DispatchTime.now().uptimeNanoseconds - origin) / 1e6
                    received.set(values)
                }
                forward?(event)
            }
            lane.conversation.readContext = { [unowned self] in full(site) }
            if projected {
                lane.conversation.readPendingAsks = { [unowned self] in narrow(site) }
            }
            lane.admissionContextProvider = { [unowned self] in full("tool-validation") }
            lane.contextProvider = { [unowned self] in
                let lines: [String]
                if projected {
                    lines = VoiceController.noteIdentityLines(asks: narrow("note"), agents: ["fixture": "Fixture"])
                } else {
                    let context = full("note")
                    lines = VoiceController.noteIdentityLines(asks: context.currentAsks, agents: context.agents)
                }
                XCTAssertEqual(lines, ["agent_id=fixture name=Fixture"])
                return "[context] " + lines.joined(separator: " · ")
            }
            lane.conversation.interpret = { [unowned self] _, context, _ in
                trace.judgments += 1
                XCTAssertEqual(row, .remote)
                return .init(kind: .task, scope: .window(context))
            }
            lane.conversation.onControl = { _ in XCTFail("unexpected action control") }
            lane.conversation.beforeAction = { [unowned self] in
                site = row == .answer || row == .replacedAsk ? "answer-check" : "target-check"
                if row == .replacedAsk { store.asks.removeAll() }
                if row == .swappedWindow { store.window += 1 }
            }
            lane.conversation.execute = { [unowned self] command in
                trace.actions += 1; trace.events["dispatch"] = clock
                XCTAssertEqual(command.admission.text, row.text)
                XCTAssertEqual(command.session, session)
                XCTAssertEqual(command.admission.turn.id, trace.turn)
                XCTAssertEqual(command.admission.realtimeInput?.itemID, trace.item)
                XCTAssertEqual(command.admission.realtimeInput?.connectionID, trace.connection)
                trace.epoch = command.epoch
                let before = store.observe()
                switch command.decision.kind {
                case .answer:
                    trace.task = command.admission.replyTo?.taskID; trace.ask = command.admission.replyTo?.askID
                    XCTAssertEqual(trace.task, taskID); XCTAssertEqual(trace.ask, askID)
                    if let ask = store.asks.first(where: { $0.taskID == trace.task && $0.askID == trace.ask }),
                       command.text == "second", ask.options.count == 2 {
                        store.chosen = ask.options[1]
                        store.asks.removeAll { $0.askID == ask.askID }
                    }
                case .scroll:
                    let request = try XCTUnwrap(command.decision.windowScroll)
                    XCTAssertEqual(request.application, "fixture.editor"); XCTAssertEqual(request.windowID, store.window)
                    XCTAssertEqual(request.direction, "down")
                    if row != .unchanged { store.viewport += request.direction == "down" ? 1 : -1 }
                case .task:
                    XCTAssertEqual(command.decision.scope?.windowID, store.window)
                    if command.text == Row.remote.text { store.notes.sort() }
                default: XCTFail("Unexpected fixture action")
                }
                await Task.yield()
                let after = store.observe()
                let effect: Bool
                switch row {
                case .remote: effect = before.notes == [2, 1] && after.notes == [1, 2]
                case .answer: effect = before.asks == [askID] && after.asks.isEmpty && store.chosen == "right"
                default: effect = after.viewport == before.viewport + 1
                }
                if effect { trace.events["observed"] = clock; trace.events["verified"] = clock }
                return .init(verified: effect, waitingForAnswer: false, message: effect ? "verified" : "no-effect")
            }
            lane.conversation.onEvent = { [unowned self] event in
                switch event {
                case .began(let turn, _): trace.inputs += 1; trace.turn = turn; site = "final-scope"
                case .source(_, let input): trace.item = input.itemID; trace.connection = input.connectionID
                case .final(_, let text):
                    trace.events["admitted"] = clock; trace.virtualAtFinal = trace.virtualMilliseconds
                    trace.captured = text; site = "process"
                case .routed(_, _, let start, let end):
                    trace.routes += 1
                    let origin = ProcessInfo.processInfo.systemUptime
                    trace.events["route-start-\(trace.routes)"] = clock + (start - origin) * 1000
                    trace.events["route-end-\(trace.routes)"] = clock + (end - origin) * 1000
                case .feedback(let id, let text):
                    XCTAssertEqual(trace.turn, id)
                    trace.terminal = text; trace.events["terminal"] = clock
                case .waiting(let id):
                    XCTAssertEqual(trace.turn, id)
                    trace.terminal = "waiting"; trace.events["terminal"] = clock
                default: break
                }
            }
            lane.onEvent = { [unowned self] id, event in
                if case .turnEnded = event, row == .remote {
                    XCTAssertEqual(trace.turn, id)
                    trace.terminal = "remote-ended"; trace.events["terminal"] = clock
                }
            }
            lane.screenShotProvider = { XCTFail("no screen"); return nil }
        }

        func narrow(_ site: String) -> [VoiceAdmissionContext.Ask] {
            trace.rawReads.append("narrow:" + site)
            return store.asks
        }

        func full(_ site: String) -> VoiceAdmissionContext {
            trace.rawReads.append("full:" + site); trace.virtualMilliseconds += delay
            var context = VoiceAdmissionContext()
            context.windowID = store.window; context.targetAppID = "fixture.editor"
            context.targetID = "window:7:\(store.window)"
            context.currentAsks = store.asks; context.capturedAsks = store.asks
            context.tasks = Set(store.asks.map(\.taskID))
            context.selectedTask = context.tasks.count == 1 ? context.tasks.first : nil
            context.agents = ["fixture": "Fixture"]
            return context
        }

        func start() async throws {
            try await lane.prepareRealtimeTransport(.conversation)
            try lane.beginRealtimeConversation(session: session)
        }

        func run(_ next: Row, delay: Int) async throws -> Trace {
            row = next; self.delay = delay; serial += 1; site = "onset"; trace = Trace()
            let choice = VoiceAdmissionContext.Ask(taskID: taskID, askID: askID, kind: .choice, options: ["left", "right"])
            store.asks = [.answer, .replacedAsk, .ambiguous].contains(next) ? [choice] : []
            if next == .ambiguous { store.asks.append(.init(taskID: UUID(), askID: UUID(), kind: .choice, options: ["second"])) }
            store.window = 100; store.notes = [2, 1]; store.chosen = nil
            await wire.setComputerGoal(row == .remote ? row.text : nil)
            let written = await wire.frames().count
            let item = "fixture-\(serial)"
            received.set([:])
            let events: [String] = ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped",
                                    "input_audio_buffer.committed", "conversation.item.input_audio_transcription.completed"]
            for (index, kind) in events.enumerated() {
                if index == 1 { trace.events["fixture-end"] = clock }
                var event: [String: JSONValue] = ["type": .string(kind), "item_id": .string(item)]
                if index == 3 { event["transcript"] = .string(row.text) }
                try await wire.push(event)
            }
            let deadline = clock + 1500
            while trace.terminal.isEmpty && clock < deadline { await Task.yield() }
            guard !trace.terminal.isEmpty else { throw VoiceError("Fixture did not settle: " + row.rawValue) }
            let frames = await wire.frames().dropFirst(written)
            for (index, kind) in events.enumerated() {
                trace.events["recv-\(index)"] = try XCTUnwrap(received.value[item + ":" + kind])
            }
            trace.responses = frames.filter { $0["type"]?.string == "response.create" }.count
            trace.tools = frames.filter { $0["item"]?["type"]?.string == "function_call_output" }.count
            if row == .remote {
                let output = try XCTUnwrap(frames.compactMap { $0["item"]?["output"]?.string }.first)
                let result = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
                XCTAssertEqual(result["status"]?.string, "completed")
            }
            XCTAssertEqual(trace.captured, row.text); XCTAssertEqual(trace.item, item); XCTAssertEqual(trace.inputs, 1)
            XCTAssertEqual(trace.responses, row == .remote ? 1 : 0); XCTAssertEqual(trace.tools, trace.responses)
            XCTAssertEqual(trace.judgments, row == .remote ? 1 : 0)
            XCTAssertEqual(trace.actions, [.move, .unchanged, .answer, .remote].contains(row) ? 1 : 0)
            XCTAssertEqual(trace.events["verified"] != nil, [.move, .answer, .remote].contains(row))
            return trace
        }
    }

    func testRecordedBaselineReadSitesAndTerminals() async throws {
        let arm = Arm(projected: false)
        try await arm.start()
        defer { arm.lane.stopConversation(); arm.client.teardown() }
        for row in Row.allCases {
            let result = try await arm.run(row, delay: 100)
            let redundant = result.rawReads.filter { ["full:process", "full:note", "full:answer-check"].contains($0) }
            if [.move, .unchanged, .answer, .remote].contains(row) {
                XCTAssertEqual(redundant.count, row == .remote ? 3 : (row == .answer ? 2 : 1), row.rawValue)
            }
            print("ASK_BASELINE \(row.rawValue) \(result.rawReads.joined(separator: ",")) \(result.terminal)")
        }
    }

    func testPendingProjectionIsFreshOrderedAndPreservesKindAndOptions() {
        func work(_ ask: DriveLoop.Ask?) -> VoiceTaskCoordinator.Work {
            let work = VoiceTaskCoordinator.Work(label: "fixture", request: "", spec: DriveTask(goal: "fixture"))
            work.agentAskID = "fixture"
            work.ask = ask
            return work
        }
        let first = work(.choice(prompt: "choose", options: ["blue", "red"])), inactive = work(.confirm("inactive"))
        inactive.active = false
        let question = work(.question("question")), confirm = work(.confirm("confirm")), unspecified = work(nil)
        let other = work(nil); other.agentAskID = nil
        let tasks = [first, inactive, other, question, confirm, unspecified]
        let old = VoiceController.pendingVoiceAsks(in: tasks)
        XCTAssertEqual(old.map(\.taskID), [first.id, question.id, confirm.id, unspecified.id])
        XCTAssertEqual(old.map(\.askID), [first.askID, question.askID, confirm.askID, unspecified.askID])
        XCTAssertEqual(old.map(\.kind), [.choice, .question, .confirm, .unspecified])
        XCTAssertEqual(old.map(\.options), [["blue", "red"], [], [], []])
        first.ask = .choice(prompt: "changed", options: ["left", "right"]); question.active = false
        let fresh = VoiceController.pendingVoiceAsks(in: tasks)
        XCTAssertEqual(fresh.map(\.taskID), [first.id, confirm.id, unspecified.id])
        XCTAssertNotEqual(fresh[0].askID, old[0].askID)
        XCTAssertEqual(fresh[0].options, ["left", "right"])
    }

    func testMatchedReadySessionAskOnlyReadsAndEffects() async throws {
        let full = Arm(projected: false), narrow = Arm(projected: true)
        try await full.start(); try await narrow.start()
        defer {
            full.lane.stopConversation(); full.client.teardown()
            narrow.lane.stopConversation(); narrow.client.teardown()
        }
        let measure = ProcessInfo.processInfo.environment["JARVIS_SYNTHETIC_ASK_BENCH"] == "1"
        let encoder = JSONEncoder()
        var rows = Data()
        for row in Row.allCases {
            let timed = [.move, .unchanged, .answer, .remote].contains(row)
            for delay in [0, 100] {
                for pair in 0..<(measure && timed ? 100 : 1) {
                    let a: Trace, b: Trace
                    if pair.isMultiple(of: 2) {
                        a = try await full.run(row, delay: delay); b = try await narrow.run(row, delay: delay)
                    } else {
                        b = try await narrow.run(row, delay: delay); a = try await full.run(row, delay: delay)
                    }
                    XCTAssertEqual(a.captured, b.captured); XCTAssertEqual(a.routes, b.routes)
                    XCTAssertEqual(a.terminal, b.terminal); XCTAssertEqual(a.actions, b.actions)
                    XCTAssertEqual(a.task, b.task); XCTAssertEqual(a.ask, b.ask)
                    XCTAssertEqual(a.responses, b.responses); XCTAssertEqual(a.tools, b.tools)
                    XCTAssertEqual(a.events["verified"] != nil, b.events["verified"] != nil)
                    let replace = ["full:process", "full:answer-check", "full:note"]
                    let expected = a.rawReads.map { replace.contains($0) ? $0.replacingOccurrences(of: "full:", with: "narrow:") : $0 }
                    XCTAssertEqual(b.rawReads, expected)
                    XCTAssertEqual(a.virtualMilliseconds - b.virtualMilliseconds, delay * a.rawReads.filter(replace.contains).count)
                    if measure {
                        for (arm, trace) in [("A", a), ("B", b)] {
                            rows.append(contentsOf: "ASK_PAIR \(row.rawValue) \(delay) \(pair) \(arm) ".utf8)
                            rows.append(try encoder.encode(trace)); rows.append(10)
                        }
                    }
                }
            }
        }
        if measure {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ask-projection-\(UUID()).jsonl")
            try rows.write(to: file, options: .withoutOverwriting)
            print("ASK_RAW " + file.path)
        }
    }
}

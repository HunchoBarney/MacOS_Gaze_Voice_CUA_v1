import XCTest
@testable import Jarvis

final class MemoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Each test gets its own temporary directory standing in for
/// Application Support, so nothing touches the real memory database.
class MemoryTestCase: XCTestCase {
    var root: URL!
    let clock = MemoryTestClock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func store(enabled: Bool = true) -> MemoryStore {
        let clock = clock
        return MemoryStore(directory: root.appendingPathComponent("Jarvis/Memory", isDirectory: true),
                           isEnabled: { enabled }, now: { clock.now })
    }

    func fileContains(_ store: MemoryStore, _ text: String) throws -> Bool {
        let directory = store.directory
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            if data.range(of: Data(text.utf8)) != nil { return true }
        }
        return false
    }
}

final class MemoryStoreTests: MemoryTestCase {
    func testDeletedMemoryNeverReturnsInLaterContextAndLeavesNoTextOnDisk() throws {
        let s = store()
        try s.remember("Dana is my manager")
        let code = try s.remember("my gate code is 4417")
        XCTAssertEqual(code.text, "My gate code is 4417")
        XCTAssertTrue(s.sessionContext(for: "what's the gate code").memories.contains(code))

        try s.delete([try XCTUnwrap(code.id)])

        let later = s.sessionContext(for: "what's the gate code")
        XCTAssertFalse(later.memories.contains { $0.id == code.id })
        XCTAssertFalse(later.instructions.contains("4417"))
        XCTAssertTrue(try s.recall("gate code").isEmpty)
        XCTAssertFalse(try fileContains(s, "4417"))
        XCTAssertEqual(try s.recall("Dana").map(\.text), ["Dana is my manager"])
    }

    func testForgetAllEmptiesEveryContextAndTheFile() throws {
        let s = store()
        try s.remember("Siobhan is my sister")
        try s.remember("I like short answers")
        try s.recordRequest("Open Calculator — Opened Calculator.")

        try s.forgetAll()

        XCTAssertEqual(s.sessionContext(for: "Siobhan"), .empty)
        XCTAssertEqual(s.sessionContext(for: nil), .empty)
        XCTAssertTrue(try s.recall("Siobhan").isEmpty)
        XCTAssertFalse(try fileContains(s, "Siobhan"))
        XCTAssertFalse(try fileContains(s, "Calculator"))
        try s.remember("Dana is my manager")
        XCTAssertEqual(s.sessionContext(for: "Dana").memories.map(\.text), ["Dana is my manager"])
    }

    func testOpensLazilyAndWritesOnlyInsideItsDirectory() throws {
        XCTAssertTrue(MemoryStore.shared.directory.path.hasSuffix("Library/Application Support/Jarvis/Memory"))

        let off = store(enabled: false)
        XCTAssertEqual(off.sessionContext(for: "Dana"), .empty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])

        let s = store()
        try s.remember("Dana is my manager")
        _ = s.sessionContext(for: "Dana")
        try s.forgetAll()
        let written = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root.path))
        XCTAssertFalse(written.isEmpty)
        for path in written {
            XCTAssertTrue(path == "Jarvis" || path.hasPrefix("Jarvis/Memory"), path)
        }
    }

    func testVoiceLiveOffGivesNoContext() throws {
        try store().remember("Dana is my manager")
        XCTAssertEqual(store(enabled: false).sessionContext(for: "Dana"), .empty)
        XCTAssertEqual(store().sessionContext(for: "Dana").memories.count, 1)
    }

    func testContextPicksMatchesFirstThenStandingPreferencesAndPeopleWithinBudget() throws {
        let s = store()
        try s.remember("Dana is my manager")
        clock.advance(1)
        try s.remember("Priya is my sister")
        clock.advance(1)
        try s.remember("I like short answers")
        clock.advance(1)
        try s.remember("the wifi password is on the fridge")
        try s.recordRequest("Open Calculator — Opened Calculator.")

        let email = s.sessionContext(for: "email Dana about the launch", limit: 3)
        XCTAssertEqual(email.memories.map(\.text),
                       ["Dana is my manager", "I like short answers", "Priya is my sister"])

        let calculator = s.sessionContext(for: "open calculator again")
        XCTAssertEqual(calculator.memories.first?.kind, .request)
        XCTAssertTrue(calculator.instructions.contains("- Earlier request: Open Calculator — Opened Calculator."))
        XCTAssertFalse(calculator.memories.contains { $0.text.contains("wifi") })

        XCTAssertEqual(s.sessionContext(for: "hello", limit: 0), .empty)
        for name in ["Ana", "Ben", "Cleo", "Dev", "Eli", "Fay", "Gus", "Hana", "Ivo", "Jun", "Kai", "Lea"] {
            try s.remember("\(name) is my colleague and " + String(repeating: "likes long meetings ", count: 12))
        }
        let full = s.sessionContext(for: nil)
        XCTAssertEqual(full.memories.count, 8)
        XCTAssertLessThanOrEqual(full.instructions.count, MemoryContext.instructionBudget)
        XCTAssertEqual(MemoryContext.empty.instructions, "")
    }

    func testPastRequestsExpireAfterNinetyDays() throws {
        let s = store()
        try s.recordRequest("Open Calculator — Opened Calculator.")
        try s.remember("I like short answers")
        clock.advance(89 * 24 * 60 * 60)
        XCTAssertEqual(s.sessionContext(for: "calculator").memories.first?.kind, .request)
        clock.advance(2 * 24 * 60 * 60)
        XCTAssertFalse(s.sessionContext(for: "calculator").memories.contains { $0.kind == .request })
        XCTAssertTrue(try s.recall("calculator").isEmpty)
        XCTAssertEqual(try s.recall("short answers").count, 1)
    }

    func testClassifiesAndRefreshesInsteadOfDuplicating() throws {
        let s = store()
        let dana = try s.remember("Dana is my manager")
        XCTAssertEqual(dana.kind, .person)
        XCTAssertEqual(dana.subject, "Dana")
        let boss = try s.remember("my manager is Dana Okafor")
        XCTAssertEqual(boss.kind, .person)
        XCTAssertEqual(boss.subject, "Dana Okafor")
        XCTAssertEqual(try s.remember("I prefer Chrome for work").kind, .preference)
        XCTAssertEqual(try s.remember("Use Chrome for work").kind, .preference)
        XCTAssertEqual(try s.remember("the spare key is under the mat").kind, .note)
        clock.advance(60)
        let again = try s.remember("Dana is my manager")
        XCTAssertEqual(again.id, dana.id)
        XCTAssertEqual(try s.recall("Dana").count, 2)
        XCTAssertThrowsError(try s.remember("   "))
        XCTAssertEqual(try s.remember(String(repeating: "a", count: 400)).text.count, MemoryStore.maxLength)
        let long = try s.remember("I like " + String(repeating: "very ", count: 60) + "short answers").text
        XCTAssertLessThanOrEqual(long.count, MemoryStore.maxLength)
        XCTAssertTrue(long.hasSuffix("very…"), long)
        XCTAssertEqual(try s.remember("dana.okafor@example.com is Dana's work email").text,
                       "dana.okafor@example.com is Dana's work email")
        XCTAssertEqual(try s.remember("iPhone passcode hint is the dog").text, "iPhone passcode hint is the dog")
        XCTAssertEqual(try s.remember("x").text, "x")
    }
}

final class MemoryCommandsTests: MemoryTestCase {
    @MainActor func testParsesTheIntentsAndLeavesOtherRequestsAlone() {
        XCTAssertEqual(MemoryIntent.parse("Remember that Dana is my manager."), .remember("Dana is my manager"))
        XCTAssertEqual(MemoryIntent.parse("please remember my gate code is 4417"), .remember("my gate code is 4417"))
        XCTAssertEqual(MemoryIntent.parse("Who's Dana?"), .recall("Dana", explicit: false))
        XCTAssertEqual(MemoryIntent.parse("who is my manager"), .recall("manager", explicit: false))
        XCTAssertEqual(MemoryIntent.parse("What do you remember about Dana?"), .recall("Dana", explicit: true))
        XCTAssertEqual(MemoryIntent.parse("what do you know about Priya"), .recall("Priya", explicit: true))
        XCTAssertEqual(MemoryIntent.parse("Forget that."), .forgetLast)
        XCTAssertEqual(MemoryIntent.parse("don't remember this"), .forgetLast)
        for other in ["remember to buy milk", "remember when we met", "open Calculator",
                      "do you remember Dana", "forget about the meeting", "remember", "who's",
                      "who's that", "who is it", "who's there"] {
            XCTAssertNil(MemoryIntent.parse(other), other)
        }
    }

    @MainActor func testReadsMemoriesBackInSecondPerson() {
        XCTAssertEqual(MemoryCommands.spoken("Dana is my manager"), "Dana is your manager.")
        XCTAssertEqual(MemoryCommands.spoken("I am allergic to peanuts"), "You are allergic to peanuts.")
        XCTAssertEqual(MemoryCommands.spoken("My gate code is 4417."), "Your gate code is 4417.")
        XCTAssertEqual(MemoryCommands.spoken("I'm vegetarian"), "You're vegetarian.")
    }

    @MainActor func testRememberRecallForgetRoundTrip() throws {
        let s = store()
        let clock = clock
        let commands = MemoryCommands(store: { s }, now: { clock.now })
        XCTAssertEqual(commands.handle("Remember Dana is my manager"), "Okay, I'll remember that.")
        XCTAssertEqual(commands.handle("Who's Dana?"), "Dana is your manager.")
        XCTAssertEqual(commands.handle("forget that"), "Okay, I've forgotten that.")
        XCTAssertNil(commands.handle("Who's Dana?"))
        XCTAssertEqual(commands.handle("What do you remember about Dana?"), "I don't remember anything about Dana.")
        XCTAssertEqual(s.sessionContext(for: "Dana"), .empty)
        XCTAssertNil(commands.handle("forget that"))
    }

    @MainActor func testForgetThatOnlyReachesTheLastMemoryForTwoMinutes() throws {
        let s = store()
        let clock = clock
        let commands = MemoryCommands(store: { s }, now: { clock.now })
        _ = commands.handle("remember I like short answers")
        clock.advance(MemoryCommands.forgetWindow + 1)
        XCTAssertNil(commands.handle("forget that"))
        XCTAssertEqual(try s.recall("short answers").count, 1)
        XCTAssertNil(commands.handle("who's the CEO of Apple"))
    }

    @MainActor func testCoordinatorAnswersMemoryIntentsOnlyWithVoiceLiveAndKeepsThemOutOfTheFeed() async throws {
        let s = store()
        let config = Config(defaults: UserDefaults(suiteName: "memory-vtc-\(UUID().uuidString)")!,
                            keyStore: NoKeys(), openAIKeyStore: NoKeys(), environment: [:])
        config.voiceLive = true
        let c = VoiceTaskCoordinator(
            config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay())
        defer { c.shutdown() }
        c.memoryCommands = MemoryCommands(store: { s })
        c.memoryStore = { s }

        let remembered = await c.beginVoiceTask("Remember my gate code is 4417")
        XCTAssertTrue(remembered.contains("I'll remember that"), remembered)
        let recalled = await c.beginVoiceTask("what do you remember about the gate code")
        XCTAssertTrue(recalled.contains("Your gate code is 4417"), recalled)
        let forgotten = await c.beginVoiceTask("forget that")
        XCTAssertTrue(forgotten.contains("forgotten"), forgotten)
        XCTAssertTrue(c.tasks.isEmpty)
        XCTAssertFalse(c.feed.entries.contains { "\($0)".contains("4417") })
        XCTAssertEqual(s.sessionContext(for: "gate code"), .empty)
    }

    @MainActor func testTypedAndHeldTurnsAdmitAnsweredMemoryIntentsLocally() async throws {
        let s = store()
        let commands = MemoryCommands(store: { s })
        _ = commands.handle("Remember Dana is my manager")
        var executed: [String] = []
        let session = LocalSpeechSession { executed.append($0.text) }
        session.memoryCommands = { commands }

        let recallDecision = await session.submitTyped("Who's Dana?", now: 1)
        let recall = try XCTUnwrap(recallDecision)
        XCTAssertEqual(recall.route, .local)
        XCTAssertEqual(recall.intent, "memory")
        let generalDecision = await session.submitTyped("Who's the CEO of Apple?", now: 2)
        let general = try XCTUnwrap(generalDecision)
        XCTAssertEqual(general.route, .remote)
        XCTAssertEqual(executed, ["Who's Dana?"])

        session.memoryCommands = { nil }
        let offDecision = await session.submitTyped("Who's Dana?", now: 3)
        let off = try XCTUnwrap(offDecision)
        XCTAssertEqual(off.route, .remote)
    }

    @MainActor func testUnreadableMemoryLeavesBareWhoQuestionsToTheModel() throws {
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let broken = MemoryStore(directory: blocker.appendingPathComponent("Memory", isDirectory: true),
                                 isEnabled: { true })
        let commands = MemoryCommands(store: { broken })
        XCTAssertFalse(commands.answers("Who's the CEO of Apple?"))
        XCTAssertTrue(commands.answers("What do you remember about Dana?"))
        XCTAssertTrue(commands.answers("Remember Dana is my manager"))
    }

    @MainActor func testHandsFreeConversationAnswersMemoryIntentsWithoutTheModel() async throws {
        let s = store()
        let commands = MemoryCommands(store: { s })
        _ = commands.handle("Remember Dana is my manager")
        let conversation = ConversationSession()
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("queue owns execution") }
            owner.context = captured
            return owner
        }
        conversation.readContext = { VoiceAdmissionContext() }
        conversation.interpret = { _, _, _ in
            XCTFail("a memory intent must not call a model")
            return .init(kind: .clarify)
        }
        conversation.remote = { _, _, _ in XCTFail("a memory intent must not reach the Live model") }
        conversation.execute = { _ in
            XCTFail("a memory intent is not a task")
            return .init(verified: false, waitingForAnswer: false, message: "")
        }
        conversation.onControl = { _ in }
        conversation.memoryCommands = { commands }
        var said: [String] = []
        conversation.onEvent = { if case .feedback(_, let message) = $0 { said.append(message) } }
        let session = UUID(), connection = UUID()
        try conversation.startExternal(session: session)
        defer { conversation.stop() }

        let turn = try conversation.beginExternal(input: .init(connectionID: connection, itemID: "who"), at: 1)
        XCTAssertTrue(conversation.commitExternal(turn, at: 2))
        await conversation.finishExternal(turn, text: "Who's Dana?", at: 2.1)
        XCTAssertEqual(said, ["Dana is your manager."])
    }

    @MainActor func testHandsFreeAnswerToAPendingQuestionIsNeverTakenAsAMemory() async throws {
        let s = store()
        let commands = MemoryCommands(store: { s })
        let ask = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .question)
        var context = VoiceAdmissionContext()
        context.capturedAsks = [ask]; context.currentAsks = [ask]
        let conversation = ConversationSession()
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in }
            owner.context = captured
            return owner
        }
        conversation.readContext = { context }
        conversation.interpret = { _, _, _ in .init(kind: .clarify) }
        conversation.remote = { _, _, _ in XCTFail("an answer to a pending question stays local") }
        conversation.execute = { _ in .init(verified: false, waitingForAnswer: false, message: "") }
        conversation.onControl = { _ in }
        conversation.memoryCommands = { commands }
        var said: [String] = []
        conversation.onEvent = { if case .feedback(_, let message) = $0 { said.append(message) } }
        let session = UUID(), connection = UUID()
        try conversation.startExternal(session: session)
        defer { conversation.stop() }

        let turn = try conversation.beginExternal(input: .init(connectionID: connection, itemID: "answer"), at: 1)
        XCTAssertTrue(conversation.commitExternal(turn, at: 2))
        await conversation.finishExternal(turn, text: "Remember Dana is my manager", at: 2.1)
        XCTAssertFalse(said.contains("Okay, I'll remember that."))
        XCTAssertEqual(try s.recall("Dana"), [])
    }

    @MainActor func testAnsweredAgentAskIsNeverKeptAsAPastRequest() async throws {
        let s = store()
        let config = Config(defaults: UserDefaults(suiteName: "memory-agent-\(UUID().uuidString)")!,
                            keyStore: NoKeys(), openAIKeyStore: NoKeys(), environment: [:])
        config.voiceLive = true
        let c = VoiceTaskCoordinator(
            config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay())
        defer { c.shutdown() }
        c.memoryStore = { s }
        let asks = root.appendingPathComponent("asks", isDirectory: true)
        try FileManager.default.createDirectory(at: asks, withIntermediateDirectories: true)
        let previous = AgentAskChannel.asksDir
        AgentAskChannel.asksDir = asks
        defer { AgentAskChannel.asksDir = previous }

        let prompt = "Deploy the staging build to production"
        let work = VoiceTaskCoordinator.Work(label: "Agent codex", request: prompt, spec: DriveTask(goal: prompt))
        work.agentAskID = "ask-\(UUID().uuidString)"
        work.ask = .confirm(prompt)
        c.tasks = [work]
        c.resolveApproval(id: work.id, approved: true)

        XCTAssertEqual(work.outcome, .done)
        XCTAssertNil(work.agentAskID)
        XCTAssertTrue(work.isAgentAsk)
        XCTAssertEqual(s.sessionContext(for: "deploy the staging build"), .empty)
    }

    @MainActor func testBareWhoRecallsOnlyRememberedFactsNeverPastRequests() throws {
        let s = store()
        try s.recordRequest("Email Dana the quarterly report — Sent.")
        let commands = MemoryCommands(store: { s })
        XCTAssertFalse(commands.answers("Who's Dana?"))
        XCTAssertNil(commands.handle("Who's Dana?"))
        _ = commands.handle("Remember Dana is my manager")
        XCTAssertTrue(commands.answers("Who's Dana?"))
        XCTAssertEqual(commands.handle("Who's Dana?"), "Dana is your manager.")
    }

    @MainActor func testHandsFreeMemoryCheckIgnoresTheWakePhrase() async throws {
        let s = store()
        let commands = MemoryCommands(store: { s })
        _ = commands.handle("Remember Dana is my manager")
        let said = try await handsFreeFeedback("Hey Jarvis, who's Dana?", commands: commands)
        XCTAssertEqual(said, ["Dana is your manager."])
    }

    @MainActor private func handsFreeFeedback(_ text: String, commands: MemoryCommands) async throws -> [String] {
        let conversation = ConversationSession()
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("queue owns execution") }
            owner.context = captured
            return owner
        }
        conversation.readContext = { VoiceAdmissionContext() }
        conversation.interpret = { _, _, _ in
            XCTFail("a memory intent must not call a model")
            return .init(kind: .clarify)
        }
        conversation.remote = { _, _, _ in XCTFail("a memory intent must not reach the Live model") }
        conversation.execute = { _ in
            XCTFail("a memory intent is not a task")
            return .init(verified: false, waitingForAnswer: false, message: "")
        }
        conversation.onControl = { _ in }
        conversation.memoryCommands = { commands }
        var said: [String] = []
        conversation.onEvent = { if case .feedback(_, let message) = $0 { said.append(message) } }
        try conversation.startExternal(session: UUID())
        defer { conversation.stop() }
        let turn = try conversation.beginExternal(input: .init(connectionID: UUID(), itemID: "turn"), at: 1)
        XCTAssertTrue(conversation.commitExternal(turn, at: 2))
        await conversation.finishExternal(turn, text: text, at: 2.1)
        return said
    }

    private struct NoKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }
}

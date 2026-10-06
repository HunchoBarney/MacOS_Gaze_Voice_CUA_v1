import XCTest
import JevVoiceCore
@testable import JevVoice

/// Regression tests for the runtime fix wave: `respond_to_task`'s `task`
/// addressing and multi-ask mux, verdict-versus-free-text routing between
/// parked consents and questions, `.needsChoice` parking a question that
/// carries its options and task identity, mid-string app-name stripping in
/// `impliedQuery`, and the timing keys every terminal path must stamp.
/// A scripted MCP driver stands in for the Cua transport.
@MainActor
final class CuaVoiceRuntimeFixesTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
        @discardableResult func bump() -> Int { lock.lock(); raw += 1; defer { lock.unlock() }; return raw }
    }

    /// Per-request pick tracking — a judge that keeps picking the same lane
    /// after its dispatch re-parks the consent it just resolved, so scripted
    /// judges dispatch once per request then report done.
    private final class PickOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: Set<String> = []
        /// True the first time a request string is seen.
        func isFirst(_ request: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return raw.insert(request).inserted
        }
    }

    private func driverScript(apps: String = "[]", windows: String = "[]",
                              elements: String = "[]",
                              listAppsDelay: Double = 0) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-fixes-\(UUID().uuidString).py")
        try """
import json,sys,time
APPS=\(apps)
WINDOWS=\(windows)
ELEMENTS=\(elements)
for line in sys.stdin:
    r=json.loads(line)
    if 'id' not in r: continue
    if r['method']=='initialize':
        out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
    elif r['method']=='tools/call':
        name=r['params']['name']; a=r['params'].get('arguments',{})
        if name=='list_apps':
            time.sleep(\(listAppsDelay))
            value={'apps':APPS}
        elif name=='launch_app': value={'pid':4242,'name':'FixAlpha','bundle_id':'test.fixalpha','windows':WINDOWS}
        elif name=='list_windows': value={'windows':WINDOWS}
        elif name=='bring_to_front': value={'activated':True,'verified':True,'exact_window_effect':{'verified':True}}
        elif name=='get_window_state': value={'window_id':a.get('window_id',7),'title':'Fixture','elements':ELEMENTS}
        elif name in ('start_session','end_session'): value={'active':name=='start_session'}
        elif name=='set_agent_cursor_enabled': value={'enabled':a.get('enabled',False)}
        else: value={'effect':'confirmed','status':'ok','summary':name+' dispatched'}
        out={'structuredContent':value}
    else:
        out={}
    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
""".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return names }
        func count(_ name: String) -> Int { values.filter { $0 == name }.count }
    }

    private func makeRuntime(script: URL,
                             judge: @escaping CuaTaskAgent.Judge,
                             calls: CallLog? = nil,
                             config: Config? = nil) -> CuaVoiceRuntime {
        let config = config ?? Config(defaults: UserDefaults(suiteName: "test.cua.fixes.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: ["JARVIS_PLANNER": "0"])
        return CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                            arguments: ["-u", script.path],
                                            onToolCall: { name, _ in calls?.record(name) }) },
            judge: judge,
            fastLaneResolver: { _, _, _, _ in nil },
            screenLocked: { false })
    }

    private nonisolated func pick(_ choice: String) -> Answer {
        .choice(choice: choice, confidence: 0.95, probabilities: [choice: 0.95])
    }
    private nonisolated func answers(next: String, fill: String = "unavailable",
                                     evidence: String = "proven", blocked: String = "other") -> [String: Answer] {
        ["next": pick(next), "fill": pick(fill),
         "doneEvidence": pick(evidence), "blockedReason": pick(blocked)]
    }
    /// Two consecutive sub-0.5 picks are what hand back a needsChoice — the
    /// probabilities carry the offered lane ids the parked ask re-lists.
    private nonisolated func hesitant(_ questions: [String: Question]) -> [String: Answer]? {
        guard case let .choice(_, criteria)? = questions["next"] else { return nil }
        let ids = criteria.keys.filter { $0 != "done" && $0 != "stuck" }.sorted()
        guard let first = ids.first else { return nil }
        let probabilities = Dictionary(uniqueKeysWithValues:
            ids.prefix(3).enumerated().map { ($0.element, 0.4 - Double($0.offset) * 0.1) })
        return ["next": .choice(choice: first, confidence: 0.3, probabilities: probabilities),
                "fill": pick("unavailable"), "doneEvidence": pick("unproven"),
                "blockedReason": pick("other")]
    }
    private nonisolated func nextLaneID(_ questions: [String: Question], containing needle: String) -> String? {
        guard case let .choice(_, criteria)? = questions["next"] else { return nil }
        return criteria.first { ($0.value ?? "").localizedCaseInsensitiveContains(needle) }?.key
    }

    private func until(_ predicate: @MainActor () -> Bool,
                       _ timeout: TimeInterval = 15,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for the voice pipeline", file: file, line: line)
    }

    private func decoded(_ json: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> VoiceToolResult {
        try XCTUnwrap(VoiceToolResult(jsonString: json),
                      "Expected a VoiceToolResult payload: \(json)", file: file, line: line)
    }

    /// The app named mid-instruction is the target, not the query: "search
    /// Spotify for X" yields X — never "Spotify for X". Leading and
    /// "for"-led occurrences strip; titles keep their words.
    func testImpliedQueryStripsMidStringAppName() {
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "Search Spotify for X", app: "Spotify"), "X")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "search Spotify for Harvest Moon", app: "Spotify"),
                       "Harvest Moon")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "search for X in Spotify", app: "Spotify"), "X")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "play Simon and Garfunkel in Spotify", app: "Spotify"),
                       "Simon and Garfunkel")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "look up the weather", app: nil), "the weather")
    }

    /// Possessive and preposition-wrapped app mentions strip whole: a
    /// possessive must never leave a leading "'s" fragment, an app wrapped
    /// in "in … for" leaves no dangling "in", and case is irrelevant.
    func testImpliedQueryPossessiveAndPrepositionVariants() {
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "search Spotify's catalog for jazz",
                                                  app: "Spotify"), "catalog for jazz")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "search in Spotify for jazz",
                                                  app: "Spotify"), "jazz")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "search spotify for harvest moon",
                                                  app: "spotify"), "harvest moon")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "SEARCH SPOTIFY FOR X",
                                                  app: "Spotify"), "X")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "play Simon and Garfunkel on spotify",
                                                  app: "spotify"), "Simon and Garfunkel")
        XCTAssertEqual(CuaVoiceRuntime.impliedQuery(in: "find the nearest coffee shop", app: nil),
                       "the nearest coffee shop")
    }

    /// The model's URL-encoded literal hand-back ("no+mistakes+by+kanye")
    /// is de-mangled only when the transcript proves the decoded form —
    /// real "+" strings stay verbatim.
    func testSanitizedLiteralTextDecodesOnlyWhenTranscriptProves() {
        XCTAssertEqual(
            CuaVoiceRuntime.sanitizedLiteralText("no+mistakes+by+kanye",
                instruction: "search and play no mistakes by kanye"),
            "no mistakes by kanye")
        XCTAssertEqual(
            CuaVoiceRuntime.sanitizedLiteralText("no%20mistakes%20by%20kanye",
                instruction: "play no mistakes by kanye on Spotify"),
            "no mistakes by kanye")
        // A real plus: "c++" has no spaced equivalent in the utterance.
        XCTAssertEqual(
            CuaVoiceRuntime.sanitizedLiteralText("type c++ code",
                instruction: "type c++ code in the editor"),
            "type c++ code")
        // Not in the instruction at all → verbatim, never invented.
        XCTAssertEqual(
            CuaVoiceRuntime.sanitizedLiteralText("hello+world",
                instruction: "search spotify for harvest moon"),
            "hello+world")
        // No encoded marker → untouched.
        XCTAssertEqual(
            CuaVoiceRuntime.sanitizedLiteralText("marvin's room drake",
                instruction: "play marvin's room by drake"),
            "marvin's room drake")
    }

    /// The agent cursor ships on and a Settings toggle re-applies on the
    /// live session transport — the mint path's one-shot enable is not the
    /// only application, and a toggle mid-session must not wait for a
    /// transport re-mint.
    func testCursorToggleReappliesOnLiveSession() async throws {
        let calls = CallLog()
        let script = try driverScript()
        let config = Config(defaults: UserDefaults(suiteName: "test.cua.cursor.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: [:])
        XCTAssertTrue(config.agentCursorEnabled, "The agent cursor defaults on")
        let runtime = makeRuntime(script: script, judge: { _, _ in self.answers(next: "done") },
                                  calls: calls, config: config)
        runtime.wakeDriverSession()
        try await until { calls.count("set_agent_cursor_enabled") == 1 }
        config.agentCursorEnabled = false
        try await until { calls.count("set_agent_cursor_enabled") == 2 }
        config.agentCursorEnabled = true
        try await until { calls.count("set_agent_cursor_enabled") == 3 }
        XCTAssertEqual(calls.count("start_session"), 1,
                       "Toggling the cursor must not re-mint the session: \(calls.values)")
        await runtime.shutdown()
    }

    /// The cold-cache accept path never waits on the driver: a roster read
    /// that stalls must not delay the "started" acknowledgement — the
    /// background refresh lands for the worker instead.
    func testColdAcceptPathAcknowledgesBeforeDriverRosterRead() async throws {
        let script = try driverScript(listAppsDelay: 1.5)
        let runtime = makeRuntime(script: script, judge: { _, _ in self.answers(next: "done") })
        let started = ProcessInfo.processInfo.systemUptime
        let ack = try decoded(await runtime.beginVoiceTask("press Save in Fixture", app: "Fixture"))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(ack.status, "started", ack.say)
        XCTAssertLessThan(elapsed, 1.0,
                          "The accept path must not wait on a cold list_apps: \(elapsed)s")
        await runtime.shutdown()
    }

    /// The wake prewarm exercises the transport and refreshes the roster —
    /// a second wake inside the cache window reuses the connection and pays
    /// no second list_apps.
    func testWakeDriverSessionWarmsTransportAndRosterOnce() async throws {
        let calls = CallLog()
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]")
        let runtime = makeRuntime(script: script, judge: { _, _ in self.answers(next: "done") },
                                  calls: calls)
        runtime.wakeDriverSession()
        try await until { calls.count("check_permissions") == 1 && calls.count("list_apps") == 1 }
        runtime.wakeDriverSession()
        try await until { calls.count("check_permissions") == 2 }
        XCTAssertEqual(calls.count("list_apps"), 1,
                       "The warm read is cached — repeat wakes must not re-list: \(calls.values)")
        XCTAssertEqual(calls.count("start_session"), 1)
        await runtime.shutdown()
    }

    /// A consent park drops the app lease: a second work bound to the same
    /// app must reach its own parked ask instead of queueing behind an
    /// unbounded user wait.
    func testSameAppConsentParkReleasesTheLease() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let once = PickOnce()
        let runtime = makeRuntime(script: script, judge: { state, questions in
            let request = state["request"]?.string ?? ""
            if once.isFirst(request), let id = self.nextLaneID(questions, containing: "Delete") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("press the Delete button in FixAlpha", app: "FixAlpha")
        let workA = try XCTUnwrap(runtime.tasks.last)
        try await until { workA.approval != nil }
        _ = await runtime.beginVoiceTask("tap the Delete control in FixAlpha", app: "FixAlpha")
        let workB = try XCTUnwrap(runtime.tasks.last)
        // If the park still held the app lease this second consent never
        // arrives — the deadline IS the assertion.
        try await until({ workB.approval != nil }, 10)
        let firstRaw = await runtime.respondToTask("yes", task: "first")
        let first = try XCTUnwrap(firstRaw)
        XCTAssertEqual(try decoded(first).status, "resumed", first)
        let lastRaw = await runtime.respondToTask("yes")
        let last = try XCTUnwrap(lastRaw)
        XCTAssertEqual(try decoded(last).status, "resumed", last)
        try await until { !workA.active && !workB.active }
        XCTAssertEqual(workA.status, "Completed", workA.message)
        XCTAssertEqual(workB.status, "Completed", workB.message)
        await runtime.shutdown()
    }

    /// A user cancel that lands while the question-parked attempt is still
    /// unwinding keeps the cancelled verdict — the settle tail must not
    /// overwrite it with the park's blocked reason.
    func testCancelledParkedQuestionKeepsTheCancelledOutcome() async throws {
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Draft','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'body0','role':'AXTextArea','label':'Body','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { _, questions in
            if let id = self.nextLaneID(questions, containing: "Type the supplied text") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("insert the reply in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertNotNil(runtime.dialogue.pendingClarification)
        runtime.cancel(work.id)
        // Let the worker's settle tail finish — the user's verdict must win.
        await work.worker?.value
        XCTAssertEqual(work.status, "Cancelled", work.message)
        if case .cancelled = work.outcome {} else {
            XCTFail("A cancelled parked question must keep the cancelled outcome: \(work.status)")
        }
        await runtime.shutdown()
    }

    /// The cold-cache accept-path roster carries only bundle-identified
    /// rows, and live rows always carry a real pid — fast-lane resolution
    /// can trust the shape without a driver read.
    func testFallbackRosterCarriesBundleIdentifiedRows() {
        for row in CuaVoiceRuntime.fallbackAppList() {
            let bundle = row["bundle_id"]?.string ?? ""
            XCTAssertFalse(bundle.isEmpty, "Every roster row needs a bundle id")
            XCTAssertFalse((row["name"]?.string ?? "").isEmpty, "Every roster row needs a name")
            if row["running"] == .bool(true) {
                XCTAssertGreaterThan(row["pid"]?.integer ?? 0, 0,
                                     "A running row needs a live pid")
            }
        }
    }

    /// A hesitant judge twice in a row hands back needsChoice — the runtime
    /// parks it as a task_question whose say is the prompt, whose options are
    /// the offered candidates, and whose detail names the owning task so the
    /// lane can address respond_to_task back at it.
    func testNeedsChoiceParksQuestionWithOptionsAndTaskIdentity() async throws {
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True},{'element_index':1,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        var events: [String] = []
        let calls = Counter()
        let runtime = makeRuntime(script: script, judge: { _, questions in
            if calls.bump() <= 2, let hesitant = self.hesitant(questions) {
                return hesitant
            }
            return self.answers(next: "done")
        })
        runtime.taskEventSink = { _, text, _ in events.append(text) }
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertTrue(work.questionParked, "A needsChoice handback parks a question, not a failure")
        let asks = events.compactMap { VoiceToolResult(jsonString: $0) }
            .filter { $0.kind == "task_question" }
        XCTAssertEqual(asks.count, 1, events.joined(separator: " | "))
        XCTAssertEqual(asks[0].status, "question")
        XCTAssertEqual(asks[0].say, "Which of these did you mean?")
        XCTAssertGreaterThanOrEqual(asks[0].options?.count ?? 0, 1)
        XCTAssertTrue(asks[0].detail?.contains("press Save in FixAlpha") ?? false,
                      "The question detail must carry the task's request: \(asks[0].detail ?? "nil")")
        XCTAssertTrue(asks[0].detail?.contains(String(work.id.uuidString.prefix(8))) ?? false,
                      "The question detail must carry the task's short id: \(asks[0].detail ?? "nil")")
        // Answering resumes the intent in place on a fresh work.
        let option = try XCTUnwrap(asks[0].options?.first)
        let replyRaw = await runtime.respondToTask(option)
        let reply = try XCTUnwrap(replyRaw)
        XCTAssertEqual(try decoded(reply).status, "resumed", reply)
        try await until { runtime.tasks.last?.active == false }
        await runtime.shutdown()
    }

    /// Parked asks resolve deterministically: a bare verdict with several
    /// waiting refuses with the list; an ordinal hint or an app-name hint
    /// picks its addressee; once one ask remains a bare verdict lands. Asks
    /// are parked sequentially so the ordinal's target is unambiguous.
    func testMultiAskRefusalAndHintedResolution() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True},{'name':'FixBeta','bundle_id':'test.fixbeta','pid':4243,'running':True},{'name':'FixGamma','bundle_id':'test.fixgamma','pid':4244,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True},{'window_id':9,'title':'FixBeta','is_on_screen':True},{'window_id':11,'title':'FixGamma','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let once = PickOnce()
        let runtime = makeRuntime(script: script, judge: { state, questions in
            let request = state["request"]?.string ?? ""
            if once.isFirst(request), let id = self.nextLaneID(questions, containing: "Delete") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("press the Delete button in FixAlpha", app: "FixAlpha")
        let workA = try XCTUnwrap(runtime.tasks.last)
        try await until { workA.approval != nil }
        _ = await runtime.beginVoiceTask("press the Delete button in FixBeta", app: "FixBeta")
        let workB = try XCTUnwrap(runtime.tasks.last)
        try await until { workB.approval != nil }
        // Bare verdict, two asks → honest refusal listing what waits.
        let bareRaw = await runtime.respondToTask("yes")
        let bare = try XCTUnwrap(bareRaw)
        let refusal = try decoded(bare)
        XCTAssertEqual(refusal.status, "refused", bare)
        XCTAssertTrue(refusal.detail?.contains("respond_to_task") ?? false,
                      "The refusal must teach the task parameter: \(refusal.detail ?? "nil")")
        XCTAssertTrue(workA.approvalContinuation != nil && workB.approvalContinuation != nil,
                      "A refused answer must not resolve either ask")
        // An ordinal hint picks the later-parked ask.
        let ordinalRaw = await runtime.respondToTask("yes", task: "second")
        let ordinal = try XCTUnwrap(ordinalRaw)
        XCTAssertEqual(try decoded(ordinal).status, "resumed", ordinal)
        try await until { !workB.active }
        XCTAssertEqual(workB.status, "Completed", workB.message)
        // Park a second ask again, then address by app name.
        _ = await runtime.beginVoiceTask("press the Delete button in FixGamma", app: "FixGamma")
        let workC = try XCTUnwrap(runtime.tasks.last)
        try await until { workC.approval != nil }
        let byNameRaw = await runtime.respondToTask("yes", task: "fixalpha")
        let byName = try XCTUnwrap(byNameRaw)
        XCTAssertEqual(try decoded(byName).status, "resumed", byName)
        try await until { !workA.active }
        XCTAssertEqual(workA.status, "Completed", workA.message)
        // One ask left — a bare verdict resolves it without a hint.
        let lastRaw = await runtime.respondToTask("yes")
        let last = try XCTUnwrap(lastRaw)
        XCTAssertEqual(try decoded(last).status, "resumed", last)
        try await until { !workC.active }
        XCTAssertEqual(workC.status, "Completed", workC.message)
        await runtime.shutdown()
    }

    /// A consent and a question parked together: verdict-shaped input resolves
    /// the consent, free text resolves the question — neither swallows the
    /// other's answer.
    func testVerdictAndFreeTextRouteToTheirOwnAskKind() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True},{'name':'FixBeta','bundle_id':'test.fixbeta','pid':4243,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True},{'window_id':9,'title':'FixBeta','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True},{'element_index':1,'element_token':'body0','role':'AXTextArea','label':'Body','enabled':True}]")
        let once = PickOnce()
        let runtime = makeRuntime(script: script, judge: { state, questions in
            let request = state["request"]?.string ?? ""
            if request.contains("FixAlpha"), once.isFirst(request) {
                if let id = self.nextLaneID(questions, containing: "Delete") {
                    return self.answers(next: id)
                }
            } else if request.contains("FixBeta"), !request.contains("user answered") {
                if let id = self.nextLaneID(questions, containing: "Type the supplied text") {
                    return self.answers(next: id, fill: "unavailable")
                }
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("press the Delete button in FixAlpha", app: "FixAlpha")
        let consent = try XCTUnwrap(runtime.tasks.last)
        try await until { consent.approval != nil }
        _ = await runtime.beginVoiceTask("insert the reply in FixBeta", app: "FixBeta")
        let questioned = try XCTUnwrap(runtime.tasks.last)
        try await until { runtime.dialogue.awaitingAnswerEntries.count == 1 }
        XCTAssertFalse(questioned.active)
        XCTAssertTrue(questioned.questionParked)
        // Free text is not verdict-shaped — it must reach the parked
        // question, not the consent's yes/no gate.
        let freeRaw = await runtime.respondToTask("the draft about taxis")
        let free = try XCTUnwrap(freeRaw)
        XCTAssertEqual(try decoded(free).status, "resumed", free)
        // The consent is still parked after the question resolved.
        XCTAssertNotNil(consent.approvalContinuation)
        // And the verdict lands on the consent, not the (now gone) question.
        let verdictRaw = await runtime.respondToTask("yes")
        let verdict = try XCTUnwrap(verdictRaw)
        XCTAssertEqual(try decoded(verdict).status, "resumed", verdict)
        try await until { !consent.active }
        XCTAssertEqual(consent.status, "Completed", consent.message)
        await runtime.shutdown()
    }

    /// A run cancelled mid-judge settles as Cancelled, and the follow-up
    /// run's parked consent still resolves to a clean Completed — no
    /// terminal path wedges the runtime.
    func testCancelledAndConsentPathsSettleCleanly() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let entered = Flag()
        let released = Flag()
        let once = PickOnce()
        let runtime = makeRuntime(script: script, judge: { state, questions in
            // The first work is cancelled while its judge is in flight; the
            // second parks a consent on Delete, then finishes.
            if !released.value {
                entered.value = true
                while !released.value { try? await Task.sleep(for: .milliseconds(5)) }
            }
            let request = state["request"]?.string ?? ""
            if once.isFirst(request), let id = self.nextLaneID(questions, containing: "Delete") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("press the Delete button in FixAlpha", app: "FixAlpha")
        let cancelled = try XCTUnwrap(runtime.tasks.last)
        try await until { entered.value }
        runtime.cancel(cancelled.id)
        released.value = true
        try await until { !cancelled.active }
        XCTAssertEqual(cancelled.status, "Cancelled", cancelled.message)
        _ = await runtime.beginVoiceTask("press the Delete button again in FixAlpha", app: "FixAlpha")
        let completed = try XCTUnwrap(runtime.tasks.last)
        try await until { completed.approval != nil }
        _ = await runtime.respondToTask("yes")
        try await until { !completed.active }
        XCTAssertEqual(completed.status, "Completed", completed.message)
        await runtime.shutdown()
    }

    /// A blocked outcome's spoken line leads with what the user can do —
    /// the generic verdict trails instead of consuming the word budget.
    func testBlockedOutcomeSayFrontLoadsTheActionableClause() async throws {
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True}]")
        var events: [String] = []
        let runtime = makeRuntime(script: script, judge: { _, _ in
            self.answers(next: "stuck", blocked: "other")
        })
        runtime.taskEventSink = { _, text, _ in events.append(text) }
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        let outcomes = events.compactMap { VoiceToolResult(jsonString: $0) }
            .filter { $0.kind == "task_outcome" }
        XCTAssertEqual(outcomes.count, 1, events.joined(separator: " | "))
        XCTAssertEqual(outcomes[0].status, "blocked")
        // "<advice>. <verdict>." — the driver's blockedReason carries the
        // actual blocking mechanism and leads; the generic verdict trails.
        XCTAssertTrue(outcomes[0].say.hasPrefix("Visual perception failed"),
                      outcomes[0].say)
        XCTAssertTrue(outcomes[0].say.hasSuffix("I couldn't finish."), outcomes[0].say)
        await runtime.shutdown()
    }
}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}

import XCTest
import JevVoiceCore
@testable import JevVoice

/// Wave-1 runtime contracts: `.done` settles only behind a dispatched
/// effect, `.alreadySatisfied` reports "Already done" — never "Done" —
/// the judge's own blocked reason reaches speech over "(other)", settle
/// evidence counts driver-grounded facts only, the roster never degrades
/// to running-only, pure opens mint `.open` scope, the completed
/// transcript owns open-app routing, and voice-supplied steps skip the
/// planner outright.
@MainActor
final class CuaRuntimeContractTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
        @discardableResult func bump() -> Int { lock.lock(); raw += 1; defer { lock.unlock() }; return raw }
    }

    /// Injected instead of nil — nil falls through to `CuaLitePlanner.shared`,
    /// which would make a real network call mid-test.
    private struct NullPlanner: CuaPlanning {
        func plan(goal: String, appName: String?, windowTitle: String?,
                  previousContext: String?) async -> DrivePlan? { nil }
    }

    private final class StubPlanner: CuaPlanning, @unchecked Sendable {
        private let calls = Counter()
        var callCount: Int { calls.value }
        func plan(goal: String, appName: String?, windowTitle: String?,
                  previousContext: String?) async -> DrivePlan? {
            calls.bump()
            return nil
        }
    }

    /// Captures the judge's previous_context — locks live inside the box so
    /// async closures never touch NSLock directly.
    private final class ContextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ""
        private var count = 0
        var value: String { lock.lock(); defer { lock.unlock() }; return stored }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func record(_ context: String) {
            lock.lock(); stored = context; count += 1; lock.unlock()
        }
    }

    private final class MemoryKeyStore: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ value: String) throws {}
        func delete() throws {}
    }

    private func driverScript(apps: String = "[]", windows: String = "[]",
                              elements: String = "[]") throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-contract-\(UUID().uuidString).py")
        try """
import json,sys
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
        if name=='list_apps': value={'apps':APPS}
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

    private func makeRuntime(
        script: URL? = nil,
        judge: @escaping CuaTaskAgent.Judge = { _, _ in [:] },
        fastLaneResolver: (@MainActor (String, String?, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)? = { _, _, _, _ in nil },
        planner: (any CuaPlanning)? = nil,
        plannerEnabled: Bool = false) -> CuaVoiceRuntime {
        let config = Config(defaults: UserDefaults(suiteName: "test.cua.contract.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: ["JARVIS_PLANNER": plannerEnabled ? "1" : "0"])
        return CuaVoiceRuntime(config: config,
            makeConnection: {
                CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                              arguments: ["-u", (script ?? URL(fileURLWithPath: "/dev/null")).path])
            },
            judge: judge,
            fastLaneResolver: fastLaneResolver,
            screenLocked: { false },
            planner: planner ?? NullPlanner())
    }

    private nonisolated func pick(_ choice: String) -> Answer {
        .choice(choice: choice, confidence: 0.95, probabilities: [choice: 0.95])
    }
    private nonisolated func answers(next: String, fill: String = "unavailable",
                                     evidence: String = "proven", blocked: String = "other") -> [String: Answer] {
        ["next": pick(next), "fill": pick(fill),
         "doneEvidence": pick(evidence), "blockedReason": pick(blocked)]
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

    private func makeLoop() -> CuaAgentLoop {
        CuaAgentLoop(call: { _, _ in .object([:]) }, judge: { _, _ in [:] })
    }

    private func makeWork(_ request: String = "press Save") -> CuaVoiceRuntime.Work {
        CuaVoiceRuntime.Work(label: "Jarvis test", request: request,
                             intentID: UUID(), attemptID: UUID())
    }

    // MARK: - .done gated on a real effect

    /// `.done` with zero dispatched effects is a claim, not a success —
    /// it settles blocked and is never spoken as "Done".
    func testDoneWithoutDispatchedEffectBlocks() {
        let runtime = makeRuntime()
        let work = makeWork("mark the flag in FixAlpha")
        let result = DriveResult(status: .done, history: ["done — the flag is set"],
                                 dispatchedEffect: false)
        let outcome = runtime.mapDriveResult(result, work: work, loop: makeLoop())
        guard case .blocked(let reason) = outcome else {
            XCTFail("a bare done claim must not settle verified: \(outcome)")
            return
        }
        XCTAssertTrue(reason.contains("nothing was dispatched"), reason)
        XCTAssertNil(work.alreadyDoneReason,
                     "a fabricated done is not an already-satisfied")
        // The blocked settle carries the honest stop reason into a retry —
        // minus the unverified tail.
        let carried = runtime.intentSpecs[work.intentID]?.goal ?? ""
        XCTAssertTrue(carried.contains("It stopped because:"), carried)
        XCTAssertFalse(carried.contains("the outcome is unverified"), carried)
    }

    /// `.done` behind a confirmed effect still settles verified — the
    /// ledger line stands in when no driver-grounded fact was recorded.
    func testDoneWithDispatchedEffectVerifies() {
        let runtime = makeRuntime()
        let work = makeWork()
        let result = DriveResult(status: .done, history: ["Saved the document"],
                                 dispatchedEffect: true)
        guard case .verified(let evidence) = runtime.mapDriveResult(result, work: work, loop: makeLoop())
        else {
            XCTFail("a dispatched done must settle verified")
            return
        }
        XCTAssertEqual(evidence, "Saved the document")
    }

    // MARK: - .alreadySatisfied is honest and distinct

    /// The goal already held: the outcome is verified-shaped (the intent
    /// succeeded), the row reads "Already done", the push reports
    /// `already_done`, and the speak names the loop's own reason.
    func testAlreadySatisfiedMapsToAlreadyDone() {
        let runtime = makeRuntime()
        let work = makeWork("open Messages")
        let reason = "Messages was already running — nothing needed launching."
        let result = DriveResult(status: .alreadySatisfied(reason: reason),
                                 dispatchedEffect: false)
        let outcome = runtime.mapDriveResult(result, work: work, loop: makeLoop())
        guard case .verified = outcome else {
            XCTFail("alreadySatisfied settles verified-shaped, not \(outcome)")
            return
        }
        XCTAssertEqual(work.alreadyDoneReason, reason)
        XCTAssertEqual(CuaVoiceRuntime.outcomeStatus(outcome, alreadyDone: true), "already_done")
        XCTAssertEqual(CuaVoiceRuntime.outcomeStatus(outcome), "verified")
        XCTAssertEqual(CuaVoiceRuntime.alreadyDoneSay(work.alreadyDoneReason),
                       "Messages was already running, nothing needed launching.")
        work.active = false
        work.outcome = outcome
        XCTAssertEqual(work.status, "Already done")
    }

    /// A reason too long to voice whole falls back to the bare verdict —
    /// truncating mid-claim would mis-speak it.
    func testAlreadyDoneSayFallsBackOnLongReasons() {
        XCTAssertEqual(CuaVoiceRuntime.alreadyDoneSay(nil), "Already done.")
        XCTAssertEqual(CuaVoiceRuntime.alreadyDoneSay(""), "Already done.")
        let long = (0 ..< 12).map { "word\($0)" }.joined(separator: " ")
        XCTAssertEqual(CuaVoiceRuntime.alreadyDoneSay(long), "Already done.")
    }

    // MARK: - Blocked speech prefers the judge's reason

    /// `blockedReason` carries the judge's stated fault — it beats the
    /// composed "(other)" sentence for both the card and the say.
    func testBlockedSpeechPrefersJudgeReason() {
        let runtime = makeRuntime()
        let work = makeWork("press Yanky in FixAlpha")
        let result = DriveResult(
            status: .blocked("The task could not be completed from FixAlpha's current state (other). Nothing further was dispatched."),
            history: ["looked at the toolbar"],
            blockedReason: "couldn't find 'Yanky'")
        let outcome = runtime.mapDriveResult(result, work: work, loop: makeLoop())
        guard case .blocked(let reason) = outcome else {
            XCTFail("expected blocked, got \(outcome)")
            return
        }
        XCTAssertEqual(reason, "couldn't find 'Yanky'")
    }

    /// A bare category key is a label, not a reason — "(other)"-class
    /// values stay with the composed message, while a key carrying real
    /// detail ("missing_info; visual perception failed: …") forwards the
    /// detail clause only.
    func testBlockedReasonSanitizesCategoryKeys() {
        XCTAssertNil(CuaVoiceRuntime.honestBlockedReason(
            DriveResult(status: .blocked("x"), blockedReason: "other")))
        XCTAssertNil(CuaVoiceRuntime.honestBlockedReason(
            DriveResult(status: .blocked("x"), blockedReason: " missing_info ")))
        XCTAssertEqual(CuaVoiceRuntime.honestBlockedReason(
            DriveResult(status: .blocked("x"),
                        blockedReason: "other; visual perception failed: window is dark")),
            "visual perception failed: window is dark")
        XCTAssertNil(CuaVoiceRuntime.honestBlockedReason(
            DriveResult(status: .blocked("x"))))
    }

    // MARK: - Settle evidence is driver-grounded

    /// `.result` (a confirmed dispatched effect) outranks `.targetObserved`,
    /// which outranks `.resultObserved`; a lone `.resultObserved` still
    /// counts — postconditions are loop-recorded driver observations, so
    /// they are valid last-resort evidence rather than model claims.
    func testSettleFactPrefersDriverGroundedKinds() {
        let intentID = UUID(), attemptID = UUID()
        func fact(_ kind: CuaDialogueState.FactKind, _ evidence: String) -> CuaDialogueState.VerifiedFact {
            .init(kind: kind, intentID: intentID, attemptID: attemptID,
                  revision: 0, evidence: evidence)
        }
        let verdict = fact(.resultObserved, "Observed the flag set.")
        let target = fact(.targetObserved, "Observed FixAlpha running.")
        let effect = fact(.result, "Pressed Save — effect confirmed.")
        XCTAssertEqual(CuaVoiceRuntime.settleFact([verdict, target, effect])?.evidence,
                       effect.evidence)
        XCTAssertEqual(CuaVoiceRuntime.settleFact([verdict, target])?.evidence,
                       target.evidence)
        XCTAssertEqual(CuaVoiceRuntime.settleFact([verdict])?.evidence,
                       verdict.evidence,
                       "a lone loop observation is valid last-resort evidence")
    }

    // MARK: - carryForward hygiene

    /// A blocked settle forwards only the honest stop clause — step-ledger
    /// tails and appended qualifiers never ride into the retry's goal.
    func testCarryForwardTrimsLedgersAndTails() {
        let runtime = makeRuntime()
        let work = makeWork("press Save in FixAlpha")
        let result = DriveResult(
            status: .blocked("Step two failed — Clicked Save → ok; judge_ms=1200. Nothing further was dispatched."),
            history: ["Clicked Save → ok"])
        _ = runtime.mapDriveResult(result, work: work, loop: makeLoop())
        let carried = try? XCTUnwrap(runtime.intentSpecs[work.intentID]?.goal)
        XCTAssertNotNil(carried)
        XCTAssertTrue(carried?.contains("Earlier attempt:") ?? false, carried ?? "")
        XCTAssertTrue(carried?.contains("It stopped because: Step two failed") ?? false, carried ?? "")
        XCTAssertFalse(carried?.contains("Clicked Save") ?? true, carried ?? "")
        XCTAssertFalse(carried?.contains("judge_ms") ?? true, carried ?? "")
    }

    /// The maxSteps ledger tail ("Stopped at the step limit — <last step>")
    /// is execution history, not an error specific — it drops off the
    /// carried reason.
    func testCarryForwardDropsStepLedgerTail() {
        let runtime = makeRuntime()
        let work = makeWork("press Save in FixAlpha")
        let result = DriveResult(status: .maxSteps(history: ["Clicked OK → ok", "Typed text → ok"]))
        _ = runtime.mapDriveResult(result, work: work, loop: makeLoop())
        let carried = runtime.intentSpecs[work.intentID]?.goal ?? ""
        XCTAssertTrue(carried.contains("It stopped because: Stopped at the step limit"), carried)
        XCTAssertFalse(carried.contains("Clicked OK"), carried)
        XCTAssertFalse(carried.contains("Typed text"), carried)
    }

    // MARK: - Installed roster never degrades to running-only

    /// The installed map lists apps that are not running — live fields
    /// come only from the caller's live rows, so `running == true` always
    /// carries a real pid.
    func testInstalledRosterCoversNotRunningApps() {
        let inventory = CuaAppInventory()
        let live: [JSONValue] = [.object([
            "name": .string("Fixture"), "bundle_id": .string("test.fixture"),
            "running": .bool(true), "pid": .number(4242)])]
        let rows = inventory.installedRoster(merging: live)
        let bundles = rows.compactMap { $0["bundle_id"]?.string }
        XCTAssertTrue(rows.count > 20, "the disk scan lists real installs: \(rows.count)")
        // macOS system apps — present on every host, running or not.
        for expected in ["com.apple.Safari", "com.apple.MobileSMS", "com.apple.iCal"] {
            XCTAssertTrue(bundles.contains(expected),
                          "installed-but-not-running apps must resolve: \(expected) missing")
        }
        for row in rows where row["running"] == .bool(true) {
            XCTAssertGreaterThan(row["pid"]?.integer ?? 0, 0,
                                 "a running claim without a pid is a fabrication: \(row)")
        }
        let fixture = rows.first { $0["bundle_id"]?.string == "test.fixture" }
        XCTAssertEqual(fixture?["pid"]?.integer, 4242)
        // Driver-only bundles (installed outside the scanned folders)
        // enter the map the moment a list_apps read reports them.
        inventory.noteDriverApps([.object([
            "name": .string("Sideways"), "bundle_id": .string("test.sideways")])])
        let merged = inventory.installedRoster(merging: [])
        XCTAssertTrue(merged.contains { $0["bundle_id"]?.string == "test.sideways" })
    }

    // MARK: - Open-scope and transcript-authoritative routing

    /// "open X" mints `.open` scope — the loop satisfies it by the app
    /// running, never by hunting for work it wasn't asked to do. A
    /// conjunction tail stays `.work`.
    func testPureOpenIntentMintsOpenScope() async throws {
        XCTAssertTrue(CuaVoiceRuntime.isPureOpenIntent("open NonexistentXYZ"))
        XCTAssertTrue(CuaVoiceRuntime.isPureOpenIntent("launch calendar"))
        XCTAssertTrue(CuaVoiceRuntime.isPureOpenIntent("bring up notes"))
        XCTAssertFalse(CuaVoiceRuntime.isPureOpenIntent("open Mail and reply to mom"))
        XCTAssertFalse(CuaVoiceRuntime.isPureOpenIntent("press Save in FixAlpha"))
        let runtime = makeRuntime()
        let ack = try decoded(await runtime.beginVoiceTask("open NonexistentXYZ", app: nil))
        XCTAssertEqual(ack.status, "started", ack.say)
        let work = try XCTUnwrap(runtime.tasks.last)
        XCTAssertEqual(runtime.intentSpecs[work.intentID]?.scope, .open)
        XCTAssertEqual(runtime.intentSpecs[work.intentID]?.application, nil)
        runtime.cancel(work.id)
        await work.worker?.value
        await runtime.shutdown()
    }

    /// The completed transcript is ground truth: "open messages" heard
    /// while the model wrote app:"Calendar" routes Messages — the resolved
    /// name reaches the fast-lane hint AND the surviving spec's
    /// application, and the open-shaped instruction is replaced by the
    /// transcript.
    func testTranscriptDivergenceRoutesHeardApp() async throws {
        var captured: (goal: String, hint: String?)?
        let runtime = makeRuntime(fastLaneResolver: { goal, hint, _, _ in
            captured = (goal, hint)
            return nil
        })
        _ = try decoded(await runtime.beginVoiceTask("open calendar", app: "Calendar",
                                                     transcriptHint: "open messages"))
        XCTAssertEqual(captured?.hint, "Messages")
        XCTAssertEqual(captured?.goal, "open messages",
                       "the transcript replaces an open-shaped instruction")
        let work = try XCTUnwrap(runtime.tasks.last)
        XCTAssertEqual(runtime.intentSpecs[work.intentID]?.application, "Messages")
        XCTAssertEqual(runtime.intentSpecs[work.intentID]?.scope, .open)
        runtime.cancel(work.id)
        await work.worker?.value
        await runtime.shutdown()
    }

    /// Same-app transcript/tool agreement changes nothing — and a
    /// transcript that fails to parse leaves the model's arg untouched.
    func testTranscriptAgreementLeavesArgsUntouched() async throws {
        var captured: (goal: String, hint: String?)?
        let runtime = makeRuntime(fastLaneResolver: { goal, hint, _, _ in
            captured = (goal, hint)
            return nil
        })
        _ = try decoded(await runtime.beginVoiceTask("open messages", app: "Messages",
                                                     transcriptHint: "open messages"))
        XCTAssertEqual(captured?.hint, "Messages")
        XCTAssertEqual(captured?.goal, "open messages")
        let garbled = try decoded(await runtime.beginVoiceTask(
            "press Save in FixAlpha", app: "FixAlpha",
            transcriptHint: "sounds like the wind"))
        XCTAssertEqual(garbled.status, "started", garbled.say)
        let work = try XCTUnwrap(runtime.tasks.last)
        XCTAssertEqual(runtime.intentSpecs[work.intentID]?.application, "FixAlpha")
        for work in runtime.tasks { runtime.cancel(work.id) }
        await runtime.shutdown()
    }

    /// "open it" + app:"Messages": the vague referent resolves through
    /// the tool's app arg — the minted fast-lane target carries the
    /// resolved bundle id.
    func testVagueOpenUsesAppHint() async throws {
        XCTAssertTrue(CuaVoiceRuntime.isVagueOpenQuery("it"))
        XCTAssertTrue(CuaVoiceRuntime.isVagueOpenQuery("the app"))
        XCTAssertFalse(CuaVoiceRuntime.isVagueOpenQuery("Safari"))
        let runtime = makeRuntime()
        _ = try decoded(await runtime.beginVoiceTask("open it", app: "Messages"))
        let work = try XCTUnwrap(runtime.tasks.last)
        XCTAssertEqual(work.bundle, "com.apple.MobileSMS",
                       "the hinted app must carry its real bundle id")
        runtime.cancel(work.id)
        await work.worker?.value
        await runtime.shutdown()
    }

    // MARK: - Voice-supplied steps bypass the planner

    /// `computer_command`'s own ordered steps fold into previous_context
    /// in the planner's "Plan: …" shape — and `planWithBudget` never runs.
    func testSuppliedStepsSkipPlanner() async throws {
        let box = ContextBox()
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True}]")
        let planner = StubPlanner()
        let runtime = makeRuntime(script: script, judge: { state, _ in
            box.record(state["previous_context"]?.string ?? "")
            return self.answers(next: "stuck")
        }, planner: planner, plannerEnabled: true)
        _ = try decoded(await runtime.beginVoiceTask("press Save then close in FixAlpha",
                                                     app: "FixAlpha",
                                                     steps: ["press Save", "close the window"]))
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertGreaterThan(box.calls, 0, "the drive loop must still judge")
        XCTAssertEqual(planner.callCount, 0, "supplied steps skip planWithBudget entirely")
        XCTAssertTrue(box.value.contains("Plan: press Save; close the window"),
                      "steps fold into previous_context: \(box.value)")
        await runtime.shutdown()
    }
}

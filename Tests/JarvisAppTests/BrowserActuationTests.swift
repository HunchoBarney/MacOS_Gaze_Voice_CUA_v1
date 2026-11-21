import XCTest
@testable import Jarvis
import JarvisCore

/// The DOM-candidate lane: `get_browser_state` refs actuate through
/// `browser_click`/`browser_type` (the typed surface — the only one that
/// resolves `p<snapshot>:<index>` refs, and `dom_event` is the sole
/// background-safe input route on macOS standalone windows), while
/// selector-addressed elements (the gaze lane's `.dom` candidates) ride
/// the legacy `page` mutations. Consent, stale-ref safety, and honest
/// refusals — never a synthesized `.done` — are the contract.
final class BrowserActuationTests: XCTestCase {

    /// A scripted driver: `responses` maps tool name → ordered results;
    /// `calls` records every (tool, args) pair dispatched.
    final class FakeDriver: @unchecked Sendable {
        var calls: [(tool: String, args: [String: JSONValue])] = []
        var responses: [String: [JSONValue]] = [:]
        var errors: [String: Error] = [:]
        var errorsOnce: [String: Error] = [:]
        var snapshotForRound: (Int) -> JSONValue = { _ in FakeDriver.emptySnap }
        private(set) var round = 0

        static let emptySnap: JSONValue = .object([
            "window_title": .string("Fixture"),
            "elements": .array([]),
        ])

        private let lock = NSLock()

        func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
            lock.lock()
            defer { lock.unlock() }
            calls.append((tool, args))
            if let error = errorsOnce.removeValue(forKey: tool) { throw error }
            if let error = errors[tool] { throw error }
            if tool == "get_window_state" {
                defer { round += 1 }
                return snapshotForRound(round)
            }
            if var queue = responses[tool], !queue.isEmpty {
                let first = queue.removeFirst()
                responses[tool] = queue
                return first
            }
            return .object(["effect": .string("confirmed")])
        }
    }

    /// The bind-mode answer once the browser endpoint is prepared.
    static let bindPayload: JSONValue = .object([
        "status": .string("ok"), "mode": .string("bind"),
        "target_id": .string("bt1"),
        "tabs": .array([
            .object(["tab_id": .string("tab1"), "title": .string("One"),
                     "active": .bool(false)]),
            .object(["tab_id": .string("tab2"), "title": .string("Two"),
                     "active": .bool(true)]),
        ]),
        "url": .string("https://example.com"),
    ])

    /// A `dom_refs_v1` snapshot — the DEFAULT payload shape: `node` is the
    /// tag, `label` a space-joined `k=v` attribute string. No `role` or
    /// `editable` keys exist on the wire.
    static let refsPayload: JSONValue = .object([
        "status": .string("ok"), "mode": .string("snapshot"),
        "snapshot_id": .string("p1"),
        "refs": .array([
            .object(["ref": .string("p1:0"), "node": .string("input"),
                     "label": .string("name=q type=text"), "frame": .string("root")]),
            .object(["ref": .string("p1:1"), "node": .string("button"),
                     "label": .string("id=go"), "frame": .string("root")]),
            .object(["ref": .string("p1:2"), "node": .string("select"),
                     "label": .string("id=country"), "frame": .string("root")]),
            .object(["ref": .string("p1:3"), "node": .string("div"),
                     "label": .string("role=textbox id=notes"), "frame": .string("root")]),
        ]),
    ])

    /// The candidate list the chooser saw, per round — the observable
    /// proof a `bt:`/`b:` option was offered.
    final class OptionsBox {
        var rounds: [[(id: String, description: String)]] = []
    }

    /// A reference box — a @Sendable seam may capture the box (a let) and
    /// mutate its property without tripping captured-var concurrency.
    final class Log {
        var entries: [String] = []
        var count = 0
    }

    override func setUp() {
        usePrivateStandingGrants()
    }

    /// A loop bound to a Safari fixture — the resolver serves the pid so
    /// `application: "safari"` resolves a real browser bundle; the task
    /// pins windowID 7 so window listing can stay empty.
    private func makeBrowserLoop(_ driver: FakeDriver,
                                 picks: [DriveLoop.JevChoice?],
                                 grant: Bool = true,
                                 ask: DriveLoop.AskFn? = nil,
                                 optionsSeen: OptionsBox? = nil,
                                 windowOnly: Bool = false,
                                 nativeReadOnly: @escaping NativeWindowObservation.Read = { _, _ in nil })
            -> DriveLoop {
        var pickQueue = picks
        let call: DriveLoop.Call = { tool, args in try driver.call(tool, args) }
        let choose: DriveLoop.Choose = { _, options in
            optionsSeen?.rounds.append(options)
            if pickQueue.isEmpty { return nil }
            return pickQueue.removeFirst()
        }
        let resolver = AppResolver.fixture(listApps: {
            [AppResolver.App(name: "Safari", bundle: "com.apple.safari", pid: 42)]
        })
        return DriveLoop.inert(call: call, choose: choose, ask: ask,
                         granted: { grant }, explicitConsent: true,
                         resolver: resolver,
                         config: .init(windowOnly: windowOnly),
                         windowControlButtons: { _ in [] },
                         windowControlPress: { _, _ in false },
                         resurrector: SessionResurrector(), nativeReadOnly: nativeReadOnly)
    }

    // MARK: - Candidate generation

    /// The v1 DOM payload carries `node`/`label` — not `role`/`editable` —
    /// so editability is inferred the way the driver's own Type action
    /// declares it: input/textarea tags and textbox-ish role attrs.
    func testBrowserTypeCandidatesFromDefaultPayload() async throws {
        let binding = BrowserSupport.Binding(targetID: "bt1", tabID: "tab2",
                                             tabs: [], pageURL: nil)
        let refs = try await BrowserSupport.snapshot(binding, session: "t") { _, _ in
            Self.refsPayload
        }
        XCTAssertEqual(refs.count, 4)
        XCTAssertEqual(refs[0].ref, "p1:0")
        XCTAssertEqual(refs[0].role, "input")
        XCTAssertTrue(refs[0].editable, "input tag is editable")
        XCTAssertFalse(refs[1].editable, "button tag is not editable")
        XCTAssertFalse(refs[2].editable, "select is click-only (combobox), not editable")
        XCTAssertTrue(refs[3].editable, "role=textbox in the v1 label string is editable")
        XCTAssertEqual(refs[3].role, "textbox")
    }

    /// `semantic_v2` payloads emit `actions` — `"type"` is authoritative.
    func testBrowserTypeCandidatesFromSemanticV2Payload() async throws {
        let binding = BrowserSupport.Binding(targetID: "bt1", tabID: "tab2",
                                             tabs: [], pageURL: nil)
        let payload: JSONValue = .object([
            "refs": .array([
                .object(["ref": .string("p9:0"), "role": .string("textbox"),
                         "name": .string("Search"),
                         "actions": .array([.string("click"), .string("type")]),
                         "states": .object(["editable": .bool(true)]),
                         "frame": .string("root"), "visibility": .string("visible")]),
                .object(["ref": .string("p9:1"), "role": .string("button"),
                         "name": .string("Go"),
                         "actions": .array([.string("click")]),
                         "states": .object([:]),
                         "frame": .string("root"), "visibility": .string("visible")]),
            ]),
        ])
        let refs = try await BrowserSupport.snapshot(binding, session: "t") { _, _ in
            payload
        }
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs[0].editable)
        XCTAssertEqual(refs[0].label, "Search")
        XCTAssertFalse(refs[1].editable)
    }

    /// The loop surfaces `bt:` candidates for editable DOM refs and types
    /// the caller's literal text through `browser_type`.
    func testBrowserTypeLoopDispatchesLiteralText() async throws {
        CuaStandingGrants.browserPageAccess = true
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? FakeDriver.emptySnap : DriveLoopTests.FakeDriver.snap([
                DriveLoopTests.FakeDriver.element(8, role: "textfield",
                                                 label: "Query", value: "hello world")
            ])
        }
        driver.responses["get_browser_state"] = [Self.bindPayload, Self.refsPayload]
        driver.responses["browser_type"] = [.object(["effect": .string("confirmed")])]
        let seen = OptionsBox()
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "bt:p1:0"), DriveLoop.JevChoice(id: "done")],
            optionsSeen: seen, nativeReadOnly: { window, _ in
                .init(elements: [], complete: true, window: window,
                      fieldValues: driver.round <= 1 ? [] : [
                    .init(role: "textfield", label: "Query", value: "hello world",
                          frame: CGRect(x: 10, y: 10, width: 80, height: 24)),
                ])
            })
        let task = DriveTask(goal: "type the supplied text into Query", application: "safari",
                             windowID: 7, values: ["text": "hello world"],
                             successContains: ["hello world"])
        let result = await loop.run(task, session: "t")
        // The editable ref produced a `bt:` candidate — button/select did not.
        let round0 = try XCTUnwrap(seen.rounds.first)
        XCTAssertTrue(round0.contains { $0.id == "bt:p1:0" })
        XCTAssertTrue(round0.contains { $0.id == "b:p1:0" })
        XCTAssertFalse(round0.contains { $0.id == "bt:p1:1" })
        XCTAssertFalse(round0.contains { $0.id == "bt:p1:2" })
        let type = try XCTUnwrap(driver.calls.last(where: { $0.tool == "browser_type" }))
        XCTAssertEqual(type.args["ref"], .string("p1:0"))
        XCTAssertEqual(type.args["text"], .string("hello world"))
        XCTAssertEqual(type.args["target_id"], .string("bt1"))
        XCTAssertEqual(type.args["tab_id"], .string("tab2"))
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
    }

    // MARK: - Click dispatch

    /// A `b:` pick dispatches `browser_click` with `input_route:
    /// "dom_event"` — the only route the driver serves into a standalone
    /// macOS browser window in background — and the synthetic click's
    /// `unverifiable` effect is honest: never counted as confirmed.
    func testBrowserClickUsesDomEventRoute() async throws {
        CuaStandingGrants.browserPageAccess = true
        let driver = FakeDriver()
        driver.responses["get_browser_state"] = [Self.bindPayload, Self.refsPayload]
        driver.responses["browser_click"] = [.object([
            "effect": .string("unverifiable"),
            "escalation": .object(["recommended": .string("page")])])]
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "b:p1:1"), DriveLoop.JevChoice(id: "done"),
                    DriveLoop.JevChoice(id: "done")])
        let task = DriveTask(goal: "enroll the widget", application: "safari",
                             windowID: 7)
        let result = await loop.run(task, session: "t")
        let click = try XCTUnwrap(driver.calls.last(where: { $0.tool == "browser_click" }))
        XCTAssertEqual(click.args["input_route"], .string("dom_event"))
        XCTAssertEqual(click.args["ref"], .string("p1:1"))
        XCTAssertEqual(click.args["target_id"], .string("bt1"))
        XCTAssertEqual(click.args["tab_id"], .string("tab2"))
        // A synthetic click can never prove activation — the run cannot
        // settle `.done` on it.
        guard case .blocked = result.status else {
            return XCTFail("an unverifiable click without goal evidence cannot claim completion: \(result.status)")
        }
        XCTAssertFalse(result.dispatchedEffect)
        XCTAssertTrue(result.history.contains { $0.contains("unverifiable") })
    }

    /// A stale ref (`browser_ref_stale`) is a page-moved-under-us signal:
    /// the loop re-observes instead of settling the task, since fresh
    /// refs stand as candidates next round.
    func testBrowserStaleRefReObserves() async throws {
        CuaStandingGrants.browserPageAccess = true
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? FakeDriver.emptySnap : DriveLoopTests.FakeDriver.status("Enrollment complete")
        }
        driver.responses["get_browser_state"] = [Self.bindPayload, Self.refsPayload]
        driver.errorsOnce["browser_click"] = DriverConnectionError.toolRefused(
            tool: "browser_click", code: "browser_ref_stale",
            detail: "the ref's node no longer resolves in the live page")
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "b:p1:1"), DriveLoop.JevChoice(id: "done")])
        let result = await loop.run(DriveTask(goal: "enroll the widget",
                                              application: "safari", windowID: 7,
                                              successContains: ["Enrollment complete"]),
                                    session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("stale ref must re-observe, not block: \(result.status)")
        }
        XCTAssertTrue(result.history.contains { $0.contains("re-observing") })
        XCTAssertEqual(driver.calls.filter { $0.tool == "get_window_state" }.count, 3)
    }

    /// The generic `stale_element_token` code on a browser ref takes the
    /// same re-observe path — never the AX identity-relocated retry and
    /// never a mislabeled "connection dropped" settle.
    func testBrowserStaleTokenCodeAlsoReObserves() async throws {
        CuaStandingGrants.browserPageAccess = true
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? FakeDriver.emptySnap : DriveLoopTests.FakeDriver.status("Enrollment complete")
        }
        driver.responses["get_browser_state"] = [Self.bindPayload, Self.refsPayload]
        driver.errorsOnce["browser_click"] = DriverConnectionError.toolRefused(
            tool: "browser_click", code: "stale_element_token",
            detail: "the element token is stale")
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "b:p1:1"), DriveLoop.JevChoice(id: "done")])
        let result = await loop.run(DriveTask(goal: "enroll the widget",
                                              application: "safari", windowID: 7,
                                              successContains: ["Enrollment complete"]),
                                    session: "t")
        guard case .alreadySatisfied = result.status else {
            return XCTFail("a stale token on a page ref must re-observe: \(result.status)")
        }
        XCTAssertTrue(result.history.contains { $0.contains("re-observing") })
    }

    // MARK: - browser_prepare consent

    func testExactWindowCannotPrepareOrRestartBrowserProfileDespiteStandingGrant() async throws {
        CuaStandingGrants.browserPageAccess = true
        let driver = FakeDriver()
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["pid": .number(42), "window_id": .number(7), "title": .string("Fixture")]),
        ])])]
        driver.snapshotForRound = { round in
            round == 0 ? DriveLoopTests.FakeDriver.snap([
                DriveLoopTests.FakeDriver.element(3, label: "Enroll"),
            ]) : DriveLoopTests.FakeDriver.status("Enrollment complete")
        }
        driver.errorsOnce["get_browser_state"] = DriverConnectionError.toolRefused(
            tool: "get_browser_state", code: "browser_requires_setup", detail: "prepare first")
        driver.responses["get_browser_state"] = [Self.bindPayload, Self.refsPayload]
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "e3"), DriveLoop.JevChoice(id: "done")],
            windowOnly: true)
        let result = await loop.run(DriveTask(goal: "enroll the widget",
            application: "safari", windowID: 7, successContains: ["Enrollment complete"]), session: "t")
        XCTAssertTrue(driver.calls.contains { $0.tool == "get_browser_state" })
        XCTAssertTrue(driver.calls.contains { $0.tool == "click" })
        XCTAssertFalse(driver.calls.contains { $0.tool == "browser_prepare" })
        XCTAssertEqual(result.status, .done)
    }

    /// No standing grant and no ask seam → `browser_prepare` never runs;
    /// the loop falls back to AX candidates rather than acting grant-free.
    func testBrowserPrepareSkippedWithoutConsent() async throws {
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? DriveLoopTests.FakeDriver.snap([
                DriveLoopTests.FakeDriver.element(3, label: "Enroll")
            ]) : DriveLoopTests.FakeDriver.status("Enrollment complete")
        }
        driver.errors["get_browser_state"] = DriverConnectionError.toolRefused(
            tool: "get_browser_state", code: "browser_requires_setup",
            detail: "prepare the browser first")
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "e3"), DriveLoop.JevChoice(id: "done")])
        let result = await loop.run(DriveTask(goal: "enroll the widget",
                                              application: "safari", windowID: 7,
                                              successContains: ["Enrollment complete"]),
                                    session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(driver.calls.contains { $0.tool == "click" })
        XCTAssertFalse(driver.calls.contains { $0.tool == "browser_prepare" },
                       "browser_prepare must not run without a grant or an approval")
        XCTAssertFalse(driver.calls.contains { $0.tool == "browser_click" })
    }

    /// The page-access standing grant admits the prepare, the retry binds,
    /// and DOM candidates become clickable the same round.
    func testBrowserPrepareRunsWithStandingGrant() async throws {
        CuaStandingGrants.browserPageAccess = true
        let driver = FakeDriver()
        driver.snapshotForRound = { round in
            round == 0 ? FakeDriver.emptySnap : DriveLoopTests.FakeDriver.status("Enrollment complete")
        }
        driver.errorsOnce["get_browser_state"] = DriverConnectionError.toolRefused(
            tool: "get_browser_state", code: "browser_requires_setup",
            detail: "prepare the browser first")
        driver.responses["get_browser_state"] = [Self.bindPayload, Self.refsPayload]
        let seen = OptionsBox()
        let loop = makeBrowserLoop(driver,
            picks: [DriveLoop.JevChoice(id: "b:p1:1"), DriveLoop.JevChoice(id: "done")],
            optionsSeen: seen)
        let result = await loop.run(DriveTask(goal: "enroll the widget",
                                              application: "safari", windowID: 7,
                                              successContains: ["Enrollment complete"]),
                                    session: "t")
        XCTAssertEqual(driver.calls.filter { $0.tool == "browser_prepare" }.count, 1)
        XCTAssertTrue(seen.rounds.first?.contains { $0.id == "b:p1:0" } ?? false,
                      "the bound page must offer DOM candidates")
        XCTAssertTrue(driver.calls.contains { $0.tool == "browser_click" })
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
    }

    /// `browser_prepare` as a direct bind call: the injected confirm is
    /// the bounded ask, and a yes is remembered as `browserPageAccess`.
    func testBrowserBindConfirmApprovalPersistsGrant() async throws {
        let prompts = Log()
        let stateCalls = Log()
        let binding = try await BrowserSupport.bind(pid: 42, windowID: 7,
            session: "t",
            call: { tool, _ in
                if tool == "get_browser_state" {
                    stateCalls.count += 1
                    if stateCalls.count == 1 {
                        throw DriverConnectionError.toolRefused(
                            tool: tool, code: "browser_requires_setup", detail: "")
                    }
                    return Self.bindPayload
                }
                return .object(["status": .string("ok")])
            },
            granted: { false },
            confirm: { prompt in prompts.entries.append(prompt); return true })
        XCTAssertNotNil(binding)
        XCTAssertEqual(binding?.tabID, "tab2", "the active row wins, not the first")
        XCTAssertEqual(prompts.entries.count, 1)
        XCTAssertTrue(CuaStandingGrants.browserPageAccess,
                      "an approved prepare persists the standing grant")
    }

    /// A declined ask skips the prepare and binds nothing — the caller
    /// keeps its AX fallback.
    func testBrowserBindConfirmDeclinedSkipsPrepare() async throws {
        let prepareCalls = Log()
        let stateCalls = Log()
        let binding = try await BrowserSupport.bind(pid: 42, windowID: 7,
            session: "t",
            call: { tool, _ in
                if tool == "browser_prepare" { prepareCalls.count += 1 }
                if tool == "get_browser_state" {
                    stateCalls.count += 1
                    throw DriverConnectionError.toolRefused(
                        tool: tool, code: "browser_requires_setup", detail: "")
                }
                return .object([:])
            },
            granted: { false },
            confirm: { _ in false })
        XCTAssertNil(binding)
        XCTAssertEqual(prepareCalls.count, 0)
        XCTAssertEqual(stateCalls.count, 1, "no consent → no retry either")
    }

    // MARK: - Selector-addressed (legacy page surface)

    /// `typeRequests` focuses with `click_element` then inserts — the
    /// driver's own sequence for selector-addressed fields.
    func testBrowserPageTypeSequenceFocusesThenInserts() {
        let requests = BrowserActuation.pageRequests(action: .insertText("hi"),
                                                     selector: "#q", pid: 42,
                                                     windowID: 7, session: "t")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].tool, "page")
        XCTAssertEqual(requests[0].args["action"], .string("click_element"))
        XCTAssertEqual(requests[0].args["selector"], .string("#q"))
        XCTAssertEqual(requests[1].args["action"], .string("insert_text"))
        XCTAssertEqual(requests[1].args["text"], .string("hi"))
        XCTAssertEqual(requests[1].args["pid"], .number(42))
        XCTAssertEqual(requests[1].args["window_id"], .number(7))
    }

    /// The keystrokes variant exists for editors that discard a bulk insert.
    func testBrowserPageTypeKeystrokesSequence() {
        let requests = BrowserActuation.pageRequests(action: .typeKeystrokes("hi"),
                                                     selector: "#q", pid: 42,
                                                     windowID: 7, session: "t")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].args["action"], .string("type_keystrokes"))
    }

    /// A gated `page` mutation refusal is honest: the outcome is a
    /// refusal that names the launch-time unlock, never a fake success.
    func testBrowserPageMutationRefusalNamesGates() async {
        let outcome = await BrowserActuation.actuate(
            [BrowserActuation.clickRequest(selector: "#x", pid: 42,
                                           windowID: 7, session: "t")],
            via: { tool, _ in
                throw DriverConnectionError.toolRefused(
                    tool: tool, code: "unbounded_operation_requires_unrestricted",
                    detail: "legacy page mutation is unbounded and requires unrestricted mode")
            })
        XCTAssertFalse(outcome.dispatched)
        XCTAssertEqual(outcome.effect, "refused")
        XCTAssertTrue(outcome.detail?.contains(BrowserActuation.legacyMutationsEnv) ?? false,
                      "the refusal must name CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS")
    }

    /// A bare `ToolResult::error` crosses `call` as `.remote` with the
    /// reason text dropped — the page gate still gets named honestly.
    func testBrowserPageMutationRemoteRefusalNamesGates() async {
        let outcome = await BrowserActuation.actuate(
            BrowserActuation.typeRequests(selector: "#q", text: "hi", pid: 42,
                                          windowID: 7, session: "t"),
            via: { _, _ in
                throw DriverConnectionError.remote(
                    "Cua could not complete page. Inspect the target before retrying.")
            })
        XCTAssertFalse(outcome.dispatched)
        XCTAssertEqual(outcome.effect, "refused")
        XCTAssertTrue(outcome.detail?.contains(BrowserActuation.legacyMutationsEnv) ?? false)
    }

    // MARK: - Gaze `.dom` parity

    private static func domCandidate(_ index: Int = 0) -> IntentCandidate {
        IntentCandidate(id: "dom:42:7:\(index)", kind: .dom,
                        frame: CGRect(x: 60, y: 10, width: 80, height: 24),
                        motorRect: CGRect(x: 60, y: 10, width: 80, height: 24),
                        role: "button", label: "Go", url: nil,
                        pid: 42, windowID: 7, appName: "Safari",
                        windowTitle: "Page", specificity: 0.85, zOrder: 0)
    }

    /// A `.dom` candidate resolves by its probe index: an
    /// `execute_javascript` stamp call first, then `click_element` on the
    /// stamped selector — cursor feedback included.
    func testBrowserDomCandidateStampsThenClicks() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let outcome = await BrowserActuation.actuate(
            candidate: Self.domCandidate(1), session: "t",
            via: { tool, args in
                calls.append((tool, args))
                if args["action"]?.string == "execute_javascript" {
                    return .object(["result": .string("{\"x\":60,\"y\":10,\"w\":80,\"h\":24}")])
                }
                return .object(["status": .string("ok")])
            })
        XCTAssertTrue(outcome.dispatched)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].1["action"], .string("execute_javascript"))
        XCTAssertEqual(calls[0].1["pid"], .number(42))
        XCTAssertEqual(calls[0].1["window_id"], .number(7))
        XCTAssertEqual(calls[1].1["action"], .string("click_element"))
        XCTAssertTrue(calls[1].1["selector"]?.string?
            .contains(BrowserActuation.stampAttribute) ?? false)
    }

    /// An index that no longer resolves stamps nothing — the actuation
    /// refuses rather than clicking a neighbor.
    func testBrowserDomCandidateRefusesWhenElementGone() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let outcome = await BrowserActuation.actuate(
            candidate: Self.domCandidate(9), session: "t",
            via: { tool, args in
                calls.append((tool, args))
                if args["action"]?.string == "execute_javascript" {
                    return .object(["result": .string("{\"error\":\"element_gone\"}")])
                }
                return .object(["status": .string("ok")])
            })
        XCTAssertFalse(outcome.dispatched)
        XCTAssertEqual(outcome.effect, "refused")
        XCTAssertFalse(calls.contains { $0.1["action"]?.string == "click_element" })
    }

    /// A reflowed element (rect far from the candidate's frame) refuses —
    /// the stamp would otherwise click the wrong node.
    func testBrowserDomCandidateRefusesWhenMoved() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let outcome = await BrowserActuation.actuate(
            candidate: Self.domCandidate(0), session: "t",
            via: { tool, args in
                calls.append((tool, args))
                if args["action"]?.string == "execute_javascript" {
                    return .object(["result": .string("{\"x\":600,\"y\":500,\"w\":80,\"h\":24}")])
                }
                return .object(["status": .string("ok")])
            })
        XCTAssertFalse(outcome.dispatched)
        XCTAssertEqual(outcome.effect, "refused")
        XCTAssertFalse(calls.contains { $0.1["action"]?.string == "click_element" })
    }

    /// Non-DOM candidates keep their own lanes — actuate refuses rather
    /// than misrouting an AX or pixel target through the page surface.
    func testBrowserNonDomCandidateRefuses() async {
        let candidate = IntentCandidate(id: "ax:42:7:tok9", kind: .axElement,
                                        frame: .zero, motorRect: .zero,
                                        role: "AXButton", label: "Save",
                                        url: nil, pid: 42, windowID: 7)
        let outcome = await BrowserActuation.actuate(candidate: candidate,
                                                     session: "t") { _, _ in
            XCTFail("a non-dom candidate must never reach the driver")
            return .object([:])
        }
        XCTAssertFalse(outcome.dispatched)
        XCTAssertEqual(outcome.effect, "refused")
    }
}

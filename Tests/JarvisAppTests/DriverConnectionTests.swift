import XCTest
@testable import Jarvis
import JarvisCore

/// Connection-level pins for the driver lane: sick-daemon wiring defaults,
/// read-retry backoff, read-only classification the pool enforces, and the
/// fire-and-forget cursor helper.
final class DriverConnectionTests: XCTestCase {
    private actor PacingWitness {
        var loads = 0
        var configurations: [[String: JSONValue]] = []
        let definitions: [JSONValue]
        let failure: DriverConnectionError?
        let foreignReply: Bool

        init(_ definitions: [JSONValue], failure: DriverConnectionError? = nil, foreignReply: Bool = false) {
            self.definitions = definitions
            self.failure = failure
            self.foreignReply = foreignReply
        }

        func load() -> [JSONValue] {
            loads += 1
            return definitions
        }

        func configure(_ arguments: [String: JSONValue]) throws -> JSONValue {
            configurations.append(arguments)
            if let failure { throw failure }
            return .object([
                "session": foreignReply ? .string("foreign") : arguments["session"]!,
                "motion": .object(["glide_duration_ms": .number(120)])
            ])
        }

        func counts() -> [Int] { [loads, configurations.count] }
    }

    private func pacingDefinitions(wait: Bool = true, motion: Bool = true) -> [JSONValue] {
        var result: [JSONValue] = [.object([
            "name": .string("click"), "inputSchema": .object(["properties": .object([
                "element_token": .object(["type": .string("string")]),
                "post_action_wait": .object(["type": .string("string"),
                    "enum": .array(wait ? [.string("default"), .string("none")] : [.string("default")])])
            ])])
        ])]
        if motion {
            result.append(.object([
                "name": .string("set_agent_cursor_motion"), "inputSchema": .object(["properties": .object([
                    "session": .object(["type": .string("string")]),
                    "glide_duration_ms": .object(["type": .string("number")])
                ])])
            ]))
        }
        return result
    }

    private var pacedInput: [String: JSONValue] {
        ["pid": .number(42), "window_id": .number(7), "session": .string("owned"),
         "element_token": .string("s00000001:3"), "post_action_wait": .string("none")]
    }

    func testNativePacingSharesSchemaCacheAndPreparesOncePerEpochAndGeneration() async throws {
        let pacing = CuaDispatchPacing()
        let witness = PacingWitness(pacingDefinitions())
        let generation = UUID(), epoch = UUID()
        for _ in 0..<2 {
            let result = try await pacing.arguments("click", pacedInput, generation: generation, epoch: epoch,
                load: { await witness.load() }, configure: { try await witness.configure($0) })
            XCTAssertEqual(result, pacedInput)
        }
        _ = try await pacing.tools(generation: generation, load: { await witness.load() })
        var counts = await witness.counts()
        XCTAssertEqual(counts, [1, 1])
        var rebound = pacedInput
        rebound["session"] = .string("rebound")
        _ = try await pacing.arguments("click", rebound, generation: generation, epoch: UUID(),
            load: { await witness.load() }, configure: { try await witness.configure($0) })
        counts = await witness.counts()
        XCTAssertEqual(counts, [1, 2])
        _ = try await pacing.arguments("click", pacedInput, generation: UUID(), epoch: epoch,
            load: { await witness.load() }, configure: { try await witness.configure($0) })
        counts = await witness.counts()
        XCTAssertEqual(counts, [2, 3])
    }

    func testDisconnectReplacesSchemaAndPreparationOwnerBeforeAnyRebind() async {
        let connection = CuaConnection()
        let previous = await connection.dispatchPacing
        await connection.close()
        let current = await connection.dispatchPacing
        XCTAssertFalse(previous === current,
                       "late calls on a retired generation must not clear the successor's preparation")
    }

    func testNativePacingCapabilitiesAreIndependentAndUnsupportedWaitIsRemoved() async throws {
        for (wait, motion) in [(false, false), (false, true), (true, false)] {
            let pacing = CuaDispatchPacing()
            let witness = PacingWitness(pacingDefinitions(wait: wait, motion: motion))
            let result = try await pacing.arguments("click", pacedInput, generation: UUID(), epoch: UUID(),
                load: { await witness.load() }, configure: { try await witness.configure($0) })
            XCTAssertEqual(result["post_action_wait"], wait ? .string("none") : nil)
            let counts = await witness.counts()
            XCTAssertEqual(counts, [1, motion ? 1 : 0])
        }
    }

    func testUnsupportedMotionRequiredFieldsUseLegacyMotionWithoutAttemptingConfiguration() async throws {
        for required in [JSONValue.array([.string("session"), .string("mode")]), .string("session")] {
            var definitions = pacingDefinitions()
            var descriptor = definitions[1].object!
            var schema = descriptor["inputSchema"]!.object!
            schema["required"] = required
            descriptor["inputSchema"] = .object(schema)
            definitions[1] = .object(descriptor)
            let witness = PacingWitness(definitions)
            let result = try await CuaDispatchPacing().arguments("click", pacedInput,
                generation: UUID(), epoch: UUID(), load: { await witness.load() },
                configure: { try await witness.configure($0) })
            XCTAssertEqual(result, pacedInput)
            let counts = await witness.counts()
            XCTAssertEqual(counts, [1, 0])
        }
    }

    func testNativePacingDoesNotDiscoverOrConfigureOutsideOwnedTokenRequests() async throws {
        let pacing = CuaDispatchPacing()
        let witness = PacingWitness(pacingDefinitions())
        var cases = ["press_key", "hotkey", "browser_click", "window_control", "get_window_state"].map {
            ($0, pacedInput)
        }
        for key in ["pid", "window_id", "session", "element_token", "post_action_wait"] {
            var arguments = pacedInput
            arguments[key] = nil
            cases.append(("click", arguments))
        }
        for (key, value) in [("capture_id", "capture"), ("session", "default"), ("element_token", "")] {
            var arguments = pacedInput
            arguments[key] = .string(value)
            cases.append(("click", arguments))
        }
        for (tool, arguments) in cases {
            let result = try await pacing.arguments(tool, arguments, generation: UUID(), epoch: UUID(),
                load: { await witness.load() }, configure: { try await witness.configure($0) })
            XCTAssertNil(result["post_action_wait"])
        }
        let counts = await witness.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testDefiniteMotionRefusalKeepsDispatchWithoutRetryingPreparation() async throws {
        let pacing = CuaDispatchPacing()
        let witness = PacingWitness(pacingDefinitions(),
            failure: .toolRefused(tool: "set_agent_cursor_motion", code: "unsupported", detail: "fixture"))
        let generation = UUID(), epoch = UUID()
        for _ in 0..<2 {
            let result = try await pacing.arguments("click", pacedInput, generation: generation, epoch: epoch,
                load: { await witness.load() }, configure: { try await witness.configure($0) })
            XCTAssertEqual(result, pacedInput)
        }
        let counts = await witness.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testClosedOrForeignMotionPreparationCannotAuthorizeInput() async {
        for witness in [PacingWitness(pacingDefinitions(), failure: .closed),
                        PacingWitness(pacingDefinitions(), foreignReply: true)] {
            do {
                _ = try await CuaDispatchPacing().arguments("click", pacedInput, generation: UUID(), epoch: UUID(),
                    load: { await witness.load() }, configure: { try await witness.configure($0) })
                XCTFail("Uncertain preparation authorized dispatch")
            } catch {
                XCTAssertTrue(error as? DriverConnectionError == .closed
                    || error as? DriverConnectionError == .malformed)
            }
        }
    }

    func testCapturedMutationRequiresOriginalTransportBeforeAnyIO() async {
        do {
            _ = try await CuaConnection().callScoped("click", arguments: [:], origin: nil)
            XCTFail("Unbound captured mutation was admitted")
        } catch {
            XCTAssertEqual(error as? DriverConnectionError,
                .refused("A capture-bound input requires its original transport scope."))
        }
    }

    func testCapturedMutationCannotSwitchProxyEvenOnSameDaemon() async {
        do {
            _ = try await CuaConnection().callScoped("type_text",
                arguments: ["session": .string("original"), "text": .string("synthetic")],
                origin: .init(session: "original", daemonSocket: "/fixture/a.sock", transport: UUID()))
            XCTFail("Another proxy's capture was admitted")
        } catch {
            XCTAssertEqual(error as? DriverConnectionError,
                .refused("The capture's transport scope is no longer current."))
        }
    }

    func testImageFeatureRequiresEveryCaptureBoundInputSchema() {
        func descriptor(_ name: String, captured: Bool) -> JSONValue {
            .object(["name": .string(name), "inputSchema": .object([
                "properties": .object(captured
                    ? ["capture_id": .object(["type": .string("string")])] : [:]),
            ])])
        }
        let names = ["click", "type_text", "press_key", "scroll"]
        XCTAssertTrue(CuaConnection.supportsCapturedInputs(.object([
            "tools": .array(names.map { descriptor($0, captured: true) }),
        ])))
        for missing in names {
            XCTAssertFalse(CuaConnection.supportsCapturedInputs(.object([
                "tools": .array(names.map { descriptor($0, captured: $0 != missing) }),
            ])))
        }
        XCTAssertFalse(CuaConnection.supportsCapturedInputs(.object(["tools": .array([])])))
    }

    func testSameLabelRevivalInvalidatesCapturedScopeWithoutProxyChange() {
        var epochs = CuaSessionEpochs()
        let captured = epochs.willCall("get_window_state", session: "original")
        XCTAssertNotNil(captured)
        XCTAssertEqual(epochs.current("original"), captured)
        XCTAssertEqual(epochs.willCall("get_window_state", session: "original"), captured)
        _ = epochs.willCall("end_session", session: "original")
        XCTAssertNotEqual(epochs.current("original"), captured)
        _ = epochs.willCall("start_session", session: "original")
        XCTAssertNotEqual(epochs.current("original"), captured)
    }

    func testCapturedNativeSupportRequiresExplicitPerToolCapability() {
        func definitions(_ name: String, flag: JSONValue?, hasToken: Bool = true) -> JSONValue {
            var properties: [String: JSONValue] = ["capture_id": .object(["type": .string("string")])]
            if hasToken { properties["element_token"] = .object(["type": .string("string")]) }
            var schema: [String: JSONValue] = ["properties": .object(properties)]
            schema["x-cua-capture-bound-element"] = flag
            return .object(["tools": .array([.object([
                "name": .string(name), "inputSchema": .object(schema),
            ])])])
        }
        for name in ["click", "type_text", "press_key", "scroll"] {
            XCTAssertEqual(CuaConnection.capturedElementTools(definitions(name, flag: .bool(true))), [name])
            for flag in [nil, JSONValue.bool(false), .string("true")] {
                XCTAssertTrue(CuaConnection.capturedElementTools(definitions(name, flag: flag)).isEmpty)
            }
            XCTAssertTrue(CuaConnection.capturedElementTools(
                definitions(name, flag: .bool(true), hasToken: false)).isEmpty)
        }
        XCTAssertTrue(CuaConnection.capturedElementTools(definitions("launch_app", flag: .bool(true))).isEmpty)
    }

    func testIndependentSessionLifecycleDoesNotInvalidateCapturedOwner() {
        var epochs = CuaSessionEpochs()
        let captured = epochs.willCall("get_window_state", session: "original")
        _ = epochs.willCall("start_session", session: "independent")
        XCTAssertEqual(epochs.current("original"), captured)
        XCTAssertNil(epochs.willCall("get_driver_info", session: nil))
    }

    func testWindowSnapshotDefaultsPreserveLegacyStructuredContract() {
        let original: [String: JSONValue] = [
            "pid": .number(42), "window_id": .number(7), "session": .string("fixture"),
            "max_elements": .number(220), "include_screenshot": .bool(false)
        ]
        var expected = original
        expected["full_output"] = .bool(true)
        XCTAssertEqual(CuaConnection.argumentsForTool("get_window_state", original), expected)
    }

    func testWindowSnapshotExplicitCallerFormatsRemainUnchanged() {
        let formats: [[String: JSONValue]] = [
            ["tree_format": .string("elements")], ["tree_format": .string("markdown")],
            ["since": .string("latest")],
            ["full_output": .bool(false)], ["full_output": .bool(true)]
        ]
        for explicit in formats {
            XCTAssertEqual(CuaConnection.argumentsForTool("get_window_state", explicit), explicit)
        }
    }

    func testWindowSnapshotAdapterDoesNotChangeOtherTools() {
        let args: [String: JSONValue] = ["pid": .number(42), "session": .string("fixture")]
        XCTAssertEqual(CuaConnection.argumentsForTool("list_windows", args), args)
    }

    // MARK: - Sick-daemon hook

    /// `onSickDaemon` was previously never wired at any construction site —
    /// a refusing-but-alive daemon was unrecoverable in-process. The init
    /// default wires the shared host's token-scoped re-mint everywhere.
    func testSickDaemonHookWiredByDefault() {
        XCTAssertNotNil(CuaConnection().onSickDaemon)
    }

    /// Explicit nil still opts out — a connection that must never recycle
    /// the shared daemon stays silent.
    func testSickDaemonHookCanBeDisabled() {
        XCTAssertNil(CuaConnection(onSickDaemon: nil).onSickDaemon)
    }

    /// A custom hook overrides the default.
    func testSickDaemonHookAcceptsOverride() {
        let conn = CuaConnection(onSickDaemon: { _ in })
        XCTAssertNotNil(conn.onSickDaemon)
    }

    // MARK: - Read-retry backoff

    /// Transient read faults retry at 150ms first — a wedged driver must
    /// not hold the first retry for ≥400ms. Cap stays 2s.
    func testReadRetryBackoffStartsAt150ms() {
        XCTAssertEqual(CuaConnection.readRetryInitialBackoff, .milliseconds(150))
        XCTAssertEqual(CuaConnection.readRetryMaxBackoff, .seconds(2))
    }

    // MARK: - Read-only classification (what callRead enforces)

    func testIsReadOnlyClassification() {
        XCTAssertTrue(CuaConnection.isReadOnly("list_apps", arguments: [:]))
        XCTAssertTrue(CuaConnection.isReadOnly("get_window_state", arguments: [:]))
        XCTAssertTrue(CuaConnection.isReadOnly("page", arguments: ["action": .string("get_text")]))
        XCTAssertFalse(CuaConnection.isReadOnly("page", arguments: ["action": .string("click_element")]))
        XCTAssertFalse(CuaConnection.isReadOnly("click", arguments: [:]))
        XCTAssertFalse(CuaConnection.isReadOnly("set_agent_cursor_enabled", arguments: [:]))
        XCTAssertFalse(CuaConnection.isReadOnly("start_session", arguments: [:]))
    }

    // MARK: - Cursor helper

    /// Fire-and-forget safe: a dead transport swallows the call — the
    /// helper never throws, so `Task { await conn.setAgentCursorEnabled }`
    /// at session start can never crash the caller.
    func testSetAgentCursorEnabledSwallowsDeadTransport() async {
        let conn = CuaConnection()
        await conn.setAgentCursorEnabled(false, session: "s")  // .closed internally — no throw
        await conn.setAgentCursorEnabled(true, session: "s")
    }
}

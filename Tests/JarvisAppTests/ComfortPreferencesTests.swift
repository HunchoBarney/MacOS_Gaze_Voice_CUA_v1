import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

/// Comfort preferences: "talk slower", "shorter answers", "bigger labels".
/// Fixtures and injected seams only — no socket, no app, no microphone.
private actor ComfortWire: RealtimeVoiceWire {
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var written: [JSONValue] = []
    var rejectStyle = false

    func send(_ text: String) throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        written.append(frame)
        guard frame["type"]?.string == "session.update" else { return }
        if rejectStyle, let id = frame["event_id"]?.string {
            try push(["type": .string("error"),
                      "error": .object(["type": .string("invalid_request_error"),
                                        "message": .string("fixture rejection"),
                                        "event_id": .string(id)])])
            return
        }
        try push(["type": .string("session.updated"), "session": frame["session"] ?? .null])
    }

    func receive() async throws -> String {
        if !incoming.isEmpty { return incoming.removeFirst() }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }

    private func push(_ object: [String: JSONValue]) throws {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        let text = String(decoding: data, as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: text) }
        else { incoming.append(text) }
    }

    func setRejectStyle(_ value: Bool) { rejectStyle = value }
    func updates() -> [JSONValue] { written.filter { $0["type"]?.string == "session.update" } }
}

@MainActor
final class ComfortPreferencesTests: XCTestCase {
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func config(_ defaults: UserDefaults) -> Config {
        Config(defaults: defaults, keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "comfort-\(UUID().uuidString)")!
    }

    private func waitFor(_ check: @MainActor () async -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < until {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("fixture wire condition timed out", file: file, line: line)
    }

    // MARK: - Phrases

    func testPhrasesParseToComfortChanges() {
        let cases: [(String, ComfortChange)] = [
            ("talk slower", .speech(.down)), ("Please speak more slowly.", .speech(.down)),
            ("Jarvis, talk a little slower", .speech(.down)),
            ("talk faster", .speech(.up)), ("speak quicker", .speech(.up)),
            ("normal speed", .speech(.reset)), ("talk normally", .speech(.reset)),
            ("shorter answers", .replies(.shorter)), ("keep it short", .replies(.shorter)),
            ("be brief", .replies(.shorter)),
            ("more detail", .replies(.detailed)), ("give me longer answers", .replies(.detailed)),
            ("normal answers", .replies(.standard)),
            ("bigger labels", .labels(.up)), ("make the labels bigger", .labels(.up)),
            ("smaller labels", .labels(.down)), ("make the numbers smaller", .labels(.down)),
            ("normal labels", .labels(.reset)), ("reset label size", .labels(.reset))
        ]
        for (phrase, expected) in cases {
            let parsed = FastAction.parse(phrase)
            guard case .comfort(let change)? = parsed?.action.body else {
                XCTFail("\(phrase) parsed as \(String(describing: parsed?.action.body))"); continue
            }
            XCTAssertEqual(change, expected, phrase)
            XCTAssertNil(parsed?.appQualifier, phrase)
        }
    }

    func testNegationsAndLookalikesAreNotComfort() {
        for phrase in ["don't talk slower", "slow down", "more detail about the weather",
                       "talk slower in safari", "bigger"] {
            if case .comfort? = FastAction.parse(phrase)?.action.body {
                XCTFail("\(phrase) must not be a comfort preference")
            }
        }
    }

    func testComfortResolvesAppFreeAndAdmitsLocally() {
        let resolved = DriveLoop.resolveFastLane(goal: "talk slower", apps: [], frontmostBundle: nil)
        guard case .comfort(.speech(.down))? = resolved?.action?.body else {
            return XCTFail("expected comfort, got \(String(describing: resolved?.action?.body))")
        }
        XCTAssertEqual(resolved?.bundle, "")
        XCTAssertFalse(DriveLoop.requiresRiskJudgment(goal: "shorter answers",
                                                      actionDescription: "Keeping answers short"))
        let proposal = VoiceAdmissionPolicy.propose("bigger labels", context: VoiceAdmissionContext())
        XCTAssertEqual(proposal.route, .local)
    }

    // MARK: - Config

    func testConfigDefaults() {
        let config = config(freshDefaults())
        XCTAssertEqual(config.speechSpeed, 1.0)
        XCTAssertEqual(config.replyLength, .standard)
        XCTAssertEqual(config.labelScale, 1.0)
    }

    func testConfigPersistsAcrossLaunches() {
        let defaults = freshDefaults()
        let first = config(defaults)
        first.speechSpeed = 0.85
        first.replyLength = .detailed
        first.labelScale = 1.5
        let relaunched = config(defaults)
        XCTAssertEqual(relaunched.speechSpeed, 0.85)
        XCTAssertEqual(relaunched.replyLength, .detailed)
        XCTAssertEqual(relaunched.labelScale, 1.5)
    }

    func testConfigClampsStoredValuesAndIgnoresUnknownLength() {
        let defaults = freshDefaults()
        defaults.set(4.0, forKey: "speechSpeed")
        defaults.set(0.1, forKey: "labelScale")
        defaults.set("rambling", forKey: "replyLength")
        let config = config(defaults)
        XCTAssertEqual(config.speechSpeed, SpeechSpeed.range.upperBound)
        XCTAssertEqual(config.labelScale, LabelScale.range.lowerBound)
        XCTAssertEqual(config.replyLength, .standard)
    }

    func testStepsStayInBoundsAndSayWhatChanged() {
        let config = config(freshDefaults())
        XCTAssertEqual(ComfortChange.speech(.down).apply(to: config), "Okay, I'll talk slower.")
        XCTAssertEqual(config.speechSpeed, 0.85)
        _ = ComfortChange.speech(.down).apply(to: config)
        _ = ComfortChange.speech(.down).apply(to: config)
        XCTAssertEqual(config.speechSpeed, 0.55)
        XCTAssertEqual(ComfortChange.speech(.down).apply(to: config), "I'm already talking as slowly as I can.")
        XCTAssertEqual(config.speechSpeed, 0.55)
        XCTAssertEqual(ComfortChange.speech(.reset).apply(to: config), "Okay, I'll talk at my normal speed.")
        XCTAssertEqual(config.speechSpeed, 1.0)
        _ = ComfortChange.speech(.up).apply(to: config)
        _ = ComfortChange.speech(.up).apply(to: config)
        XCTAssertEqual(config.speechSpeed, 1.3)
        XCTAssertEqual(ComfortChange.speech(.up).apply(to: config), "I'm already talking as fast as I can.")

        XCTAssertEqual(ComfortChange.replies(.shorter).apply(to: config), "Okay, I'll keep my answers short.")
        XCTAssertEqual(config.replyLength, .shorter)

        XCTAssertEqual(ComfortChange.labels(.down).apply(to: config), "The labels are already as small as they go.")
        for _ in 0..<6 { _ = ComfortChange.labels(.up).apply(to: config) }
        XCTAssertEqual(config.labelScale, 2.0)
        XCTAssertEqual(ComfortChange.labels(.reset).apply(to: config), "Okay, the labels are back to their normal size.")
        XCTAssertEqual(config.labelScale, 1.0)
    }

    func testFastLaneStoresThePreferenceAndSpeaksIt() async {
        let config = config(freshDefaults())
        let old = DriveLoop.applyComfort
        defer { DriveLoop.applyComfort = old }
        DriveLoop.applyComfort = { change in await MainActor.run { change.apply(to: config) } }
        let loop = DriveLoop(call: { _, _ in .object(["apps": .array([])]) },
                             choose: { _, _ in nil }, ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "talk slower"), session: "t")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(result.history.last, "Okay, I'll talk slower.")
        XCTAssertEqual(config.speechSpeed, 0.85)
    }

    // MARK: - Realtime session

    func testBrevityReachesTheInstructions() {
        let standard = RealtimeVoiceClient.instructions(for: .standard)
        XCTAssertEqual(standard, RealtimeVoiceClient.instructions)
        let shorter = RealtimeVoiceClient.instructions(for: .shorter)
        XCTAssertTrue(shorter.hasPrefix(RealtimeVoiceClient.instructions))
        XCTAssertTrue(shorter.contains("one\nshort sentence") || shorter.contains("one short sentence"))
        let detailed = RealtimeVoiceClient.instructions(for: .detailed)
        XCTAssertTrue(detailed.contains("more detail"))
        XCTAssertNotEqual(shorter, detailed)
    }

    func testConnectCarriesTheStoredStyle() async throws {
        let wire = ComfortWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        try await client.setReplyStyle(.init(speed: 0.7, length: .shorter))
        try await client.connect(apiKey: "fixture-not-a-real-key")
        let updates = await wire.updates()
        XCTAssertEqual(updates.count, 1, "the style rides the first configuration")
        let session = try XCTUnwrap(updates.first?["session"])
        XCTAssertEqual(session["audio"]?["output"]?["speed"], .number(0.7))
        XCTAssertEqual(session["instructions"]?.string, RealtimeVoiceClient.instructions(for: .shorter))
    }

    func testStyleChangeOnLiveSessionSendsSpeedAndInstructions() async throws {
        let wire = ComfortWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        try await client.connect(apiKey: "fixture-not-a-real-key")
        let first = await wire.updates()
        XCTAssertEqual(first.first?["session"]?["audio"]?["output"]?["speed"], .number(1.0))

        try await client.setReplyStyle(.init(speed: 0.85, length: .detailed))
        await waitFor { await wire.updates().count == 2 }
        let updates = await wire.updates()
        let update = try XCTUnwrap(updates.last)
        XCTAssertTrue(update["event_id"]?.string?.hasPrefix("sty-") == true)
        XCTAssertEqual(update["session"]?["type"]?.string, "realtime")
        XCTAssertEqual(update["session"]?["audio"]?["output"]?["speed"], .number(0.85))
        XCTAssertNil(update["session"]?["audio"]?["input"], "a style change leaves input alone")
        XCTAssertEqual(update["session"]?["instructions"]?.string, RealtimeVoiceClient.instructions(for: .detailed))
        XCTAssertTrue(client.isReady, "the microphone path never waits on a style change")

        try await client.configureInput(.manual)
        XCTAssertEqual(client.inputMode, .manual, "the style ack never stands in for an input confirmation")
        XCTAssertTrue(client.isReady)
    }

    func testRejectedStyleChangeLeavesSessionUsable() async throws {
        let wire = ComfortWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        try await client.connect(apiKey: "fixture-not-a-real-key")
        await wire.setRejectStyle(true)
        try await client.setReplyStyle(.init(speed: 1.3, length: .standard))
        await waitFor { await wire.updates().count == 2 }
        await wire.setRejectStyle(false)
        try await client.configureInput(.manual)
        XCTAssertEqual(client.inputMode, .manual)
        XCTAssertTrue(client.isReady)
    }

    func testUnchangedStyleSendsNothing() async throws {
        let wire = ComfortWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        try await client.connect(apiKey: "fixture-not-a-real-key")
        try await client.setReplyStyle(.init())
        let count = await wire.updates().count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Overlay

    func testLabelScaleReachesTheOverlayFontSizes() {
        let standard = TargetOverlay.LabelSizes(scale: 1.0)
        XCTAssertEqual(standard.number, 13)
        XCTAssertEqual(standard.caption, 12)
        XCTAssertEqual(standard.chipSide, TargetOverlay.minChipSide)
        XCTAssertEqual(standard.cheatLine, 15)
        let big = TargetOverlay.LabelSizes(scale: 1.5)
        XCTAssertEqual(big.number, 19.5)
        XCTAssertEqual(big.caption, 18)
        XCTAssertEqual(big.chipSide, TargetOverlay.minChipSide * 1.5)
        XCTAssertEqual(TargetOverlay.LabelSizes(scale: 9), TargetOverlay.LabelSizes(scale: 2))
        XCTAssertEqual(TargetOverlay.LabelSizes(scale: 0), TargetOverlay.LabelSizes(scale: 1))

        let overlay = TargetOverlay()
        XCTAssertEqual(overlay.labelSizes, standard)
        let config = config(freshDefaults())
        _ = ComfortChange.labels(.up).apply(to: config)
        overlay.labelScale = config.labelScale
        XCTAssertEqual(overlay.labelSizes.number, 13 * 1.25)
        overlay.showNames(targets: [(frame: CGRect(x: 10, y: 10, width: 40, height: 20), label: "Save")])
        overlay.hideAll()
    }
}

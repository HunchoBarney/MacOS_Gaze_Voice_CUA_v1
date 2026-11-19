import Foundation
import XCTest
@testable import JevVoice

/// The auth link and config staging: system-auth providers get a symlink
/// into the isolated CODEX_HOME — never a copy — so token rotation in the
/// real ~/.codex/auth.json reaches every agent.
final class CodexRuntimeBridgeTests: XCTestCase {
    func testTurnReceiptMatchesExactWorkerThreadAndSession() {
        var first = WorkerTurnLedger(agent: "a", thread: "shared")
        var second = WorkerTurnLedger(agent: "b", thread: "shared")
        let a = first.accept("1", start: first.begin())
        let b = second.accept("1", start: second.begin())
        first.finish(thread: "foreign", turn: .init(id: "1", status: "completed"))
        XCTAssertEqual(first.status(a), .working)
        second.finish(thread: "shared", turn: .init(id: "1", status: "failed"))
        XCTAssertEqual(second.status(b), .failed)
        XCTAssertEqual(second.status(a), .unknown)
        XCTAssertEqual(first.status(b), .unknown)
        XCTAssertEqual(WorkerTurnLedger(agent: "a", thread: "shared").status(a), .unknown)
        first.interruptSubmitted(a)
        XCTAssertEqual(first.status(a), .unknown)
        first.finish(thread: "shared", turn: .init(id: "1", status: "interrupted"))
        XCTAssertEqual(first.status(a), .interrupted)
    }

    func testTerminalBeforeAcceptanceIsLifecycleOnlyAndEvictionIsUnknown() {
        var ledger = WorkerTurnLedger(agent: "w", thread: "t")
        let earlier = ledger.begin()
        let start = ledger.begin()
        ledger.finish(thread: "t", turn: .init(id: "early", status: "completed"))
        let early = ledger.accept("early", start: start)
        XCTAssertEqual(ledger.status(early), .workerFinished)
        for n in 0..<17 {
            ledger.finish(thread: "t", turn: .init(id: String(n), status: "completed"))
        }
        XCTAssertEqual(ledger.status(early), .unknown)
        let late = ledger.accept("0", start: earlier)
        XCTAssertEqual(ledger.status(late), .unknown)
        XCTAssertFalse(ledger.active.contains(late))
        ledger.finish(thread: "t", turn: .init(id: "early", status: "failed"))
        XCTAssertEqual(ledger.status(early), .unknown)
        let live = ledger.accept("new", start: ledger.begin())
        XCTAssertEqual(ledger.status(live), .working)
        ledger.finish(thread: "t", turn: .init(id: "new", status: "unexpected"))
        XCTAssertEqual(ledger.status(live), .unknown)
    }

    func testDuplicatedStartIDsNeverShareAStatus() {
        var ledger = WorkerTurnLedger(agent: "worker", thread: "thread")
        let first = ledger.accept("repeated", start: ledger.begin())
        let duplicate = ledger.accept("repeated", start: ledger.begin())
        ledger.finish(thread: "thread", turn: .init(id: "repeated", status: "completed"))
        XCTAssertNotEqual(first, duplicate)
        XCTAssertEqual(ledger.status(first), .unknown)
        XCTAssertEqual(ledger.status(duplicate), .unknown)
    }

    func testDuplicateAfterEarlyEvictionCannotConfirmOrBecomeAnInterruptTarget() {
        var ledger = WorkerTurnLedger(agent: "w", thread: "t")
        let start = ledger.begin()
        ledger.finish(thread: "t", turn: .init(id: "x", status: "failed"))
        for n in 0..<16 { ledger.finish(thread: "t", turn: .init(id: String(n), status: "completed")) }
        ledger.finish(thread: "t", turn: .init(id: "x", status: "completed"))
        let receipt = ledger.accept("x", start: start)
        XCTAssertEqual(ledger.status(receipt), .unknown)
        XCTAssertFalse(ledger.active.contains(receipt))
    }

    private var root: URL!
    private var home: URL!
    private var source: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbridge-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("codex-home", isDirectory: true)
        source = root.appendingPathComponent("codex/auth.json")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSource() throws {
        try "{\"tokens\":{}}".write(to: source, atomically: true, encoding: .utf8)
    }

    private var link: URL { home.appendingPathComponent("auth.json") }

    func testLinkCreatedWhenSourceExists() throws {
        try writeSource()
        CodexRuntimeBridge.linkSystemAuth(into: home, source: source)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       source.path)
        // Reading through the link must reach the real credential.
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testMissingSourceLeavesHomeHonest() throws {
        CodexRuntimeBridge.linkSystemAuth(into: home, source: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testRealFileMigratesToLink() throws {
        try writeSource()
        try "stale-copy".write(to: link, atomically: true, encoding: .utf8)
        CodexRuntimeBridge.linkSystemAuth(into: home, source: source)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       source.path)
    }

    func testWrongLinkIsRepointed() throws {
        try writeSource()
        let other = root.appendingPathComponent("elsewhere/auth.json")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{}".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        CodexRuntimeBridge.linkSystemAuth(into: home, source: source)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       source.path)
    }

    func testCorrectLinkIsLeftAlone() throws {
        try writeSource()
        CodexRuntimeBridge.linkSystemAuth(into: home, source: source)
        let attrs1 = try FileManager.default.attributesOfItem(atPath: link.path)
        CodexRuntimeBridge.linkSystemAuth(into: home, source: source)
        let attrs2 = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attrs1[.modificationDate] as? Date, attrs2[.modificationDate] as? Date)
    }

    func testSystemAuthConfigEmitsNoProviderTable() {
        let toml = CodexRuntimeBridge.configTOML(provider: .chatGPT(model: "gpt-5"), mcpServers: [])
        XCTAssertTrue(toml.contains("model = \"gpt-5\""))
        XCTAssertFalse(toml.contains("model_provider"), "system auth must not emit a provider override")
        XCTAssertFalse(toml.contains("env_key"))
    }

    func testEnvKeyConfigEmitsProviderTable() {
        let provider = CodexModelProvider(name: "openai", baseURL: "https://api.openai.com/v1",
                                        envKey: "OPENAI_API_KEY", model: "")
        let toml = CodexRuntimeBridge.configTOML(provider: provider, mcpServers: [])
        XCTAssertTrue(toml.contains("[model_providers.\"openai\"]"))
        XCTAssertTrue(toml.contains("env_key = \"OPENAI_API_KEY\""))
    }
}

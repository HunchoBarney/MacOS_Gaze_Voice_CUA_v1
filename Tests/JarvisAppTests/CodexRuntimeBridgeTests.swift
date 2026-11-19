import Foundation
import XCTest
@testable import Jarvis

/// The auth link and config staging: system-auth providers get a symlink
/// into the isolated CODEX_HOME — never a copy — so token rotation in the
/// real ~/.codex/auth.json reaches every agent.
final class CodexRuntimeBridgeTests: XCTestCase {
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

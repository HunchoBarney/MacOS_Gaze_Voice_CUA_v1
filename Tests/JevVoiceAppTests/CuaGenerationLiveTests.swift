import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaGenerationLiveTests: XCTestCase {
    func testObservedDocumentSummaryOptIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_CUA_GENERATION_TEST"] == "1", let jevKey = env["TYPESAFE_API_KEY"], let groqKey = env["GROQ_API_KEY"] else {
            throw XCTSkip("Opt-in real Cua/Jev/Groq fixture summary")
        }
        let connection = CuaConnection()
        try await connection.connect()
        let label = "Jarvis summary fixture \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(label)])
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis-Summary-\(UUID()).txt")
            try "The blue notebook is on the desk. It belongs to the fictional Copper Lantern project.".write(to: file, atomically: true, encoding: .utf8)
            let opened = try await connection.call("launch_app", arguments: ["bundle_id": .string("com.apple.TextEdit"), "urls": .array([.string(file.path)]), "session": .string(label)])
            let pid = try XCTUnwrap(opened["pid"]?.integer)
            let windows = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(label)])
            let matches = (windows["windows"]?.array ?? []).filter { $0["title"]?.string?.contains(file.lastPathComponent) == true }
            XCTAssertEqual(matches.count, 1)
            let window = try XCTUnwrap(matches.first?["window_id"]?.integer)
            let jev = JevClient(apiKey: jevKey)
            let provider = TextGenerationClient(baseURL: URL(string: "https://api.groq.com/openai/v1")!, model: "qwen/qwen3.8-27b", key: groqKey)
            var providerCalls = 0, mutations = 0
            let agent = CuaTaskAgent(call: { tool, arguments in
                if !["list_apps", "get_accessibility_tree", "list_windows", "get_window_state"].contains(tool) { mutations += 1; throw DriverConnectionError.refused("Summary tried to mutate its source") }
                return try await connection.call(tool, arguments: arguments.merging(["session": .string(label)]) { _, b in b })
            }, judge: { state, questions in try await jev.systemOne(state: state, questions: questions).response.answers }, windowID: window, generate: { prompt, context, reasoning in
                providerCalls += 1
                XCTAssertTrue(context.contains("blue notebook"))
                XCTAssertTrue(context.contains("Copper Lantern"))
                return try await provider.generate(prompt: prompt, context: context, reasoning: reasoning)
            })
            let start = ContinuousClock.now
            let result = try await agent.run(goal: "Summarize this TextEdit document in one sentence, preserving all its facts.", context: "The supplied window is the disposable source document.", progress: { print("Summary fixture:", $0) })
            XCTAssertEqual(providerCalls, 1)
            XCTAssertEqual(mutations, 0)
            for fact in ["blue notebook", "desk", "copper lantern"] { XCTAssertTrue(result.lowercased().contains(fact), "Summary omitted a required fixture fact") }
            print("Observed document summary duration:", start.duration(to: .now))
            print("Disposable summary result:", result)
        } catch {
            _ = try? await connection.call("end_session", arguments: ["session": .string(label)])
            await connection.close()
            throw error
        }
        _ = try await connection.call("end_session", arguments: ["session": .string(label)])
        await connection.close()
    }
}

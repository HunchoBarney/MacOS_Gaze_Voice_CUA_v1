import XCTest
@testable import JevVoiceCore

final class TextGenerationTests: XCTestCase {
    func testRateLimitExplainsDelayWithoutReflectingProviderContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for host in ["numeric.test", "untrusted.test"] {
            let client = TextGenerationClient(baseURL: URL(string: "https://\(host)/v1")!, model: "fixture", key: "fixture", session: session)
            do {
                _ = try await client.generate(prompt: "Draft a greeting", context: "Disposable fixture")
                XCTFail("A rate-limited response must not produce a draft")
            } catch {
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("rate limit"))
                XCTAssertTrue(message.contains("not retried"))
                XCTAssertFalse(message.contains("private-provider-content"))
                if host == "numeric.test" { XCTAssertTrue(message.contains("12 seconds")) }
            }
        }
    }
    func testEndpointAllowsHTTPSAndLoopbackOnlyWithoutEmbeddedCredentials() throws {
        XCTAssertNoThrow(try TextGenerationClient.endpoint("https://api.groq.com/openai/v1"))
        XCTAssertNoThrow(try TextGenerationClient.endpoint("http://127.0.0.1:8080/v1"))
        for bad in ["http://example.com/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/provider"] {
            XCTAssertThrowsError(try TextGenerationClient.endpoint(bad))
        }
    }
    func testRequestUsesSelectedModelAndQwenReasoningWithoutTools() throws {
        let client = TextGenerationClient(baseURL: try TextGenerationClient.endpoint("https://api.groq.com/openai/v1"), model: "qwen/qwen3.8-27b", key: "fixture-key")
        let request = try client.request(prompt: "Summarize", context: "Fixture", reasoning: true)
        let json = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(json["model"], .string("qwen/qwen3.8-27b"))
        XCTAssertEqual(json["reasoning_effort"], .string("low"))
        XCTAssertNil(json["tools"])
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
    }
    func testResponseRejectsToolsEmptyAndTruncation() throws {
        for body in [#"{"choices":[{"finish_reason":"tool_calls","message":{"content":null}}]}"#,
                     #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#,
                     #"{"choices":[{"finish_reason":"stop","message":{"content":""}}]}"#] {
            XCTAssertThrowsError(try TextGenerationClient.text(from: Data(body.utf8)))
        }
        let valid = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"A short summary."}}]}"#.utf8)
        XCTAssertEqual(try TextGenerationClient.text(from: valid), "A short summary.")
    }
}

private final class RateLimitProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delay = request.url?.host == "numeric.test" ? "12" : "private-provider-content"
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": delay])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private-provider-content".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

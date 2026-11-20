import Foundation
import XCTest
@testable import JarvisCore

private final class VisionHTTP: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func take() -> [URLRequest] { lock.withLock {
            defer { requests.removeAll() }
            return requests
        } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: 4096)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.state.record(captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"model":"jev-1.14.0","answers":{}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class JevClientTests: XCTestCase {
    private func client() -> JevClient {
        _ = VisionHTTP.state.take()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VisionHTTP.self]
        return JevClient(apiKey: "synthetic-not-a-key", model: "jev-1.14.0",
                         session: URLSession(configuration: config))
    }

    func testLegacyRequestHasNoAssetsOrImageOptInHeader() async throws {
        _ = try await client().systemOne(state: ["goal": "press Search"], questions: [
            "possible": .noul(instructions: "Is a Search control available?"),
        ])
        let request = try XCTUnwrap(VisionHTTP.state.take().first)
        XCTAssertNil(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                                 as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "state", "questions"])
        XCTAssertEqual((body["state"] as? [String: String])?["goal"], "press Search")
    }

}

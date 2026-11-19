import CoreGraphics
import Foundation
import ImageIO
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
    private let reference = "6419f37e-0f99-4f39-b3ee-93bc1608e20f"

    private func client() -> JevClient {
        _ = VisionHTTP.state.take()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VisionHTTP.self]
        return JevClient(apiKey: "synthetic-not-a-key", model: "jev-1.14.0",
                         session: URLSession(configuration: config))
    }

    private func png(width: Int = 280, height: Int = 280) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
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

    func testImageAssetIsTopLevelAndReferencedOnceWithOptInHeader() async throws {
        let image = try JevImageAsset(data: png(), format: .png)
        _ = try await client().systemOne(state: ["window_image": reference], questions: [
            "location": .box(instructions: "the Search control in `window_image`"),
        ], assets: [reference: image])
        let request = try XCTUnwrap(VisionHTTP.state.take().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images"), "true")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                                 as? [String: Any])
        let assets = try XCTUnwrap(body["assets"] as? [String: [String: String]])
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets[reference]?["format"], "png")
        XCTAssertEqual(assets[reference]?["type"], "image")
        XCTAssertNotNil(Data(base64Encoded: assets[reference]?["data_base64"] ?? ""))
        XCTAssertEqual((body["state"] as? [String: String])?["window_image"], reference)
    }

    func testBoxWithoutImageRefusesBeforeNetwork() async {
        let api = client()
        do {
            _ = try await api.systemOne(state: ["goal": "Search"], questions: [
                "location": .box(instructions: "the Search control"),
            ])
            XCTFail("box sent without image")
        } catch {}
        XCTAssertTrue(VisionHTTP.state.take().isEmpty)
    }

    func testAssetReferenceInObjectKeyDoesNotCount() async throws {
        let api = client()
        let image = try JevImageAsset(data: png(), format: .png)
        do {
            _ = try await api.systemOne(state: [reference: "not an image reference"], questions: [
                "possible": .noul(instructions: "Is a target visible?"),
            ], assets: [reference: image])
            XCTFail("unused image sent")
        } catch {}
        XCTAssertTrue(VisionHTTP.state.take().isEmpty)
    }

    func testImageAssetRejectsInvalidBytesDimensionsAndOversizeFile() throws {
        XCTAssertThrowsError(try JevImageAsset(data: Data([1, 2, 3]), format: .png))
        XCTAssertThrowsError(try JevImageAsset(data: png(width: 279), format: .png))
        XCTAssertThrowsError(try JevImageAsset(data: png(width: 1569), format: .png))
        XCTAssertThrowsError(try JevImageAsset(data: png(), format: .jpeg))
        XCTAssertThrowsError(try JevImageAsset(data: Data(repeating: 0, count: 16 * 1024 * 1024 + 1),
                                             format: .png))
    }
}

import CoreGraphics
import ImageIO
import XCTest
@testable import Jarvis
import JarvisCore

/// Contract for piece 5 of JARA-36: the reusable Terra client and the
/// one-window picture. No network and no screen: the client runs on a
/// fake transport, and redaction runs on a synthetic image.
final class TerraClientTests: XCTestCase {

    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["answer": .object(["type": .string("string")])]),
        "required": .array([.string("answer")]),
        "additionalProperties": .bool(false),
    ])

    private func request(images: [Data] = []) -> TerraClient.Request {
        .init(instructions: "Answer briefly.", text: "What is this?", images: images,
              schemaName: "screen_answer", schema: schema)
    }

    private func reply(_ json: String, status: Int = 200) -> TerraClient.Transport {
        { request in
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
        }
    }

    private static let answer = #"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"answer\":\"A photo of a dog\"}"}]}]}"#

    func testBodyAsksTerraForStrictJSONAndKeepsNothing() throws {
        let body = TerraClient.body(for: request(images: [Data([0x89, 0x50])]))
        XCTAssertEqual(body["model"]?.string, "gpt-6.1-terra")
        XCTAssertEqual(body["store"]?.bool, false)
        XCTAssertEqual(body["reasoning"]?["effort"]?.string, "low")
        XCTAssertEqual(body["text"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(body["text"]?["format"]?["strict"]?.bool, true)
        XCTAssertEqual(body["text"]?["format"]?["schema"], schema)
        let content = try XCTUnwrap(body["input"]?.array?.first?["content"]?.array)
        XCTAssertEqual(content.first?["type"]?.string, "input_text")
        XCTAssertEqual(content.last?["type"]?.string, "input_image")
        XCTAssertEqual(content.last?["image_url"]?.string, "data:image/png;base64,iVA=")
    }

    func testRespondSendsTheKeyOnlyInTheHeaderAndDecodesTheAnswer() async throws {
        let seen = LockedBox<URLRequest?>(nil)
        var client = TerraClient(apiKey: { "sk-test" })
        let ok = reply(Self.answer)
        client.transport = { request in seen.set(request); return try await ok(request) }
        struct Answer: Decodable { var answer: String }
        let answer = try await client.respond(request(), as: Answer.self)
        XCTAssertEqual(answer.answer, "A photo of a dog")
        let sent = try XCTUnwrap(seen.value)
        XCTAssertEqual(sent.url, TerraClient.endpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertFalse(String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("sk-test"))
    }

    func testMissingKeyNeverCallsOpenAI() async {
        let called = LockedBox(false)
        var client = TerraClient(apiKey: { "  " })
        client.transport = { _ in called.set(true); throw URLError(.badURL) }
        do {
            _ = try await client.respond(request())
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? TerraClient.Failure, .missingKey)
        }
        XCTAssertFalse(called.value)
    }

    func testFailuresAreTyped() async {
        let cases: [(String, Int, TerraClient.Failure)] = [
            (#"{"error":{"message":"Incorrect API key provided"}}"#, 401,
             .http(status: 401, message: "Incorrect API key provided")),
            (#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I can't help with that."}]}]}"#, 200,
             .refused("I can't help with that.")),
            (#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#, 200,
             .incomplete("max_output_tokens")),
            (#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"not json"}]}]}"#, 200,
             .malformed),
        ]
        for (json, status, expected) in cases {
            var client = TerraClient(apiKey: { "sk-test" })
            client.transport = reply(json, status: status)
            do {
                _ = try await client.respond(request())
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? TerraClient.Failure, expected)
            }
        }
    }

    // MARK: - Window picture

    func testPixelSizeCapsTheLongEdge() {
        XCTAssertEqual(WindowCapture.pixelSize(points: CGSize(width: 400, height: 300), scale: 2),
                       CGSize(width: 800, height: 600))
        XCTAssertEqual(WindowCapture.pixelSize(points: CGSize(width: 1440, height: 900), scale: 2),
                       CGSize(width: 1280, height: 800))
        XCTAssertEqual(WindowCapture.pixelSize(points: CGSize(width: 500, height: 1600), scale: 1),
                       CGSize(width: 400, height: 1280))
    }

    func testRedactionFramesMapIntoThePicture() {
        let window = CGRect(x: 100, y: 100, width: 100, height: 50)
        let rects = WindowCapture.imageRects(
            for: [CGRect(x: 110, y: 110, width: 20, height: 10),
                  CGRect(x: 190, y: 140, width: 40, height: 40),
                  CGRect(x: 500, y: 500, width: 10, height: 10)],
            windowFrame: window, imageSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(rects, [CGRect(x: 16, y: 16, width: 48, height: 28),
                               CGRect(x: 176, y: 76, width: 24, height: 24)])
    }

    func testRedactedPixelsAreBlackAndTheRestIsUntouched() throws {
        let image = try XCTUnwrap(Self.whiteImage(width: 200, height: 100))
        let redacted = try XCTUnwrap(WindowCapture.redact(
            image, windowFrame: CGRect(x: 100, y: 100, width: 100, height: 50),
            redactions: [CGRect(x: 110, y: 110, width: 20, height: 10)]))
        let pixels = try XCTUnwrap(Self.rgba(redacted))
        XCTAssertEqual(pixels(20, 20), [0, 0, 0, 255], "inside the password box")
        XCTAssertEqual(pixels(63, 43), [0, 0, 0, 255], "bottom-right of the padded box")
        XCTAssertEqual(pixels(70, 20), [255, 255, 255, 255])
        XCTAssertEqual(pixels(20, 60), [255, 255, 255, 255])
        let png = try XCTUnwrap(WindowCapture.encodePNG(redacted))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testIncompleteRedactionsRefuseBeforeAnyCapture() async {
        do {
            _ = try await WindowCapture.capture(windowID: 1, redactions: [], redactionsComplete: false)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? WindowCapture.Failure, .redactionsIncomplete)
        }
    }

    private static func whiteImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    /// A reader for (x, y) with y counted from the top.
    private static func rgba(_ image: CGImage) -> ((Int, Int) -> [UInt8])? {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return { x, y in Array(buffer[(y * width + x) * 4 ..< (y * width + x) * 4 + 4]) }
    }
}


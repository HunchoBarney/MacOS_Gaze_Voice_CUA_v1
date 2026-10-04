import AVFoundation
import XCTest
@testable import JevVoice

/// Stubbed URLProtocol so the TTS contract is tested without network.
private final class StubbedURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    static var cancelled = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.cancelled += 1 }
}

private final class RecordingSpeech: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    var onSpeak: (() -> Void)?
    func speak(_ text: String) {
        lock.lock(); spoken.append(text); lock.unlock()
        onSpeak?()
    }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    func texts() -> [String] { lock.lock(); defer { lock.unlock() }; return spoken }
}

private final class FakePlayer: AVAudioPlayer {
    private(set) var plays = 0
    private(set) var stops = 0
    var onPlay: (() -> Void)?
    override func play() -> Bool { plays += 1; onPlay?(); return true }
    override func stop() { stops += 1 }
}

/// ~30ms of 8kHz mono 16-bit PCM silence — parses as valid AVAudioPlayer input.
private func wavData() -> Data {
    let frames = 240
    var data = Data("RIFF".utf8)
    func u32(_ v: UInt32) { var v = v.littleEndian; data.append(Data(bytes: &v, count: 4)) }
    func u16(_ v: UInt16) { var v = v.littleEndian; data.append(Data(bytes: &v, count: 2)) }
    u32(UInt32(36 + frames * 2)); data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
    data.append(contentsOf: "data".utf8); u32(UInt32(frames * 2))
    data.append(contentsOf: [UInt8](repeating: 0, count: frames * 2))
    return data
}

final class ElevenLabsSpeechOutputTests: XCTestCase {
    private var session: URLSession!
    private var fallback: RecordingSpeech!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedURLProtocol.self]
        session = URLSession(configuration: config)
        fallback = RecordingSpeech()
        StubbedURLProtocol.handler = nil
        StubbedURLProtocol.requests = []
        StubbedURLProtocol.cancelled = 0
    }

    private func pump(_ seconds: TimeInterval = 0.25) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func testRequestCarriesContract() {
        let output = ElevenLabsSpeechOutput(apiKey: "sk-test", voiceID: "voice-1",
                                            modelID: "model-9", session: session)
        let request = output.request(for: "hello")
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.url!.absoluteString.contains("text-to-speech/voice-1"))
        XCTAssertEqual(request!.value(forHTTPHeaderField: "xi-api-key"), "sk-test")
        let body = try! JSONSerialization.jsonObject(with: request!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["text"] as? String, "hello")
        XCTAssertEqual(body["model_id"] as? String, "model-9")
    }

    func testEmptyAPIKeyReturnsNilRequestAndFallsBack() {
        let output = ElevenLabsSpeechOutput(apiKey: "", session: session, fallback: fallback)
        XCTAssertNil(output.request(for: "hi"))
        output.speak("hi there")
        pump()
        XCTAssertEqual(fallback.texts(), ["hi there"])
        XCTAssertTrue(StubbedURLProtocol.requests.isEmpty)
    }

    func testDisabledOutputDropsSilently() {
        let output = ElevenLabsSpeechOutput(apiKey: "k", session: session,
                                            fallback: fallback, enabled: false)
        output.speak("should not be heard")
        pump()
        XCTAssertTrue(fallback.texts().isEmpty)
        XCTAssertTrue(StubbedURLProtocol.requests.isEmpty)
    }

    func testEmptyTextDoesNothing() {
        let output = ElevenLabsSpeechOutput(apiKey: "k", session: session, fallback: fallback)
        output.speak("   ")
        pump()
        XCTAssertTrue(fallback.texts().isEmpty)
        XCTAssertTrue(StubbedURLProtocol.requests.isEmpty)
    }

    func testFailedRequestFallsBack() {
        StubbedURLProtocol.handler = { _ in (401, Data("unauthorized".utf8)) }
        let heard = expectation(description: "fallback spoke")
        fallback.onSpeak = { heard.fulfill() }
        let output = ElevenLabsSpeechOutput(apiKey: "k", session: session,
                                            fallback: fallback,
                                            makePlayer: { try FakePlayer(data: $0) })
        output.speak("say this")
        wait(for: [heard], timeout: 3)
        XCTAssertEqual(fallback.texts(), ["say this"])
        XCTAssertEqual(StubbedURLProtocol.requests.count, 1)
    }

    func testSuccessfulRequestPlaysAudio() {
        StubbedURLProtocol.handler = { _ in (200, wavData()) }
        let player = try! FakePlayer(data: wavData())
        let played = expectation(description: "player played")
        player.onPlay = { played.fulfill() }
        let output = ElevenLabsSpeechOutput(apiKey: "k", session: session,
                                            fallback: fallback,
                                            makePlayer: { _ in player })
        output.speak("hello")
        wait(for: [played], timeout: 3)
        pump()
        XCTAssertTrue(fallback.texts().isEmpty)
        XCTAssertEqual(player.plays, 1)
    }

    func testStopCancelsTaskAndStopsFallback() {
        StubbedURLProtocol.handler = { _ in (200, wavData()) }
        let output = ElevenLabsSpeechOutput(apiKey: "k", session: session,
                                            fallback: fallback,
                                            makePlayer: { try FakePlayer(data: $0) })
        output.speak("hello")
        output.stop()
        pump()
        XCTAssertEqual(fallback.stops, 1)
    }

    func testSupersededSpeakInvalidatesInFlightResponse() {
        // First request hangs until cancelled; second completes. The stale
        // response must never play audio.
        StubbedURLProtocol.handler = { _ in (200, wavData()) }
        let player = try! FakePlayer(data: wavData())
        let output = ElevenLabsSpeechOutput(apiKey: "k", session: session,
                                            fallback: fallback,
                                            makePlayer: { _ in player })
        output.speak("first")
        output.speak("second")
        pump(0.5)
        XCTAssertLessThanOrEqual(player.plays, 1)
        XCTAssertTrue(fallback.texts().isEmpty)
    }
}

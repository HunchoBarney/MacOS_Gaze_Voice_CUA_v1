import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

/// Jarvis's credential service, faked in memory: no request leaves the Mac.
private actor FakeService {
    struct Seen: Equatable { let path: String; let authorization: String? }
    private(set) var seen: [Seen] = []
    private var registrations = 0
    var realtimeReplies: [(Int, String)] = []
    private var forgotten: Set<String> = []
    private var staleMints = 0

    func setRealtimeReplies(_ replies: [(Int, String)]) { realtimeReplies = replies }

    /// Mints with this token fail as `unknown_install`. The first stale mint
    /// waits for a second one, and the second waits until a mint with a
    /// fresh token arrives, so both callers fail on the old token and the
    /// later failure lands after the earlier caller registered again.
    func forget(_ token: String) { forgotten.insert(token) }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path() ?? ""
        seen.append(Seen(path: path, authorization: request.value(forHTTPHeaderField: "Authorization")))
        let (status, body): (Int, String)
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        if path == "/base/v1/realtime/client_secret", let bearer, forgotten.contains(bearer) {
            staleMints += 1
            if staleMints == 1 {
                try await until { staleMints >= 2 }
            } else {
                try await until { seen.contains { $0.path == path && !forgotten.contains(($0.authorization ?? "").replacingOccurrences(of: "Bearer ", with: "")) } }
            }
            let body = #"{"error":{"code":"unknown_install","message":"This install isn't registered."}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        switch path {
        case "/base/v1/installs":
            registrations += 1
            try await Task.sleep(for: .milliseconds(20))
            (status, body) = (201, #"{"installID":"install-\#(registrations)","token":"jv1_token\#(registrations)"}"#)
        case "/base/v1/realtime/client_secret" where !realtimeReplies.isEmpty:
            (status, body) = realtimeReplies.removeFirst()
        case "/base/v1/realtime/client_secret":
            (status, body) = (200, #"{"value":"ek_fixture","expiresAt":1900000000,"model":"gpt-realtime-fixture"}"#)
        default:
            (status, body) = (404, #"{"error":{"code":"not_found","message":"No such endpoint."}}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private final class TokenBox: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() throws -> String? { lock.withLock { value } }
    func save(_ apiKey: String) throws { lock.withLock { value = apiKey } }
    func delete() throws { lock.withLock { value = nil } }
}

private struct NoKeys: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

/// Answers each session.update with session.updated, so a connect completes.
private actor EchoWire: RealtimeVoiceWire {
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?

    func send(_ text: String) throws {
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard frame["type"]?.string == "session.update" else { return }
        let reply = String(decoding: try JSONEncoder().encode(JSONValue.object([
            "type": .string("session.updated"), "session": frame["session"] ?? .null,
        ])), as: UTF8.self)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: reply)
        } else {
            queue.append(reply)
        }
    }

    func receive() async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

final class HostedCredentialsTests: XCTestCase {
    private let base = URL(string: "https://keys.example/base")!

    private func hosted(_ service: FakeService, tokens: TokenBox = TokenBox()) -> HostedCredentials {
        HostedCredentials(baseURL: base, tokenStore: tokens, transport: { try await service.handle($0) })
    }

    private func config(hosted: HostedCredentials?, environment: [String: String] = [:]) -> Config {
        Config(defaults: UserDefaults(suiteName: "hosted-\(UUID().uuidString)")!,
               keyStore: NoKeys(), openAIKeyStore: NoKeys(), environment: environment, hosted: hosted)
    }

    func testServiceURLTakesHTTPSOrThisMacOnly() {
        func url(_ environment: [String: String], _ info: Any? = nil) -> String? {
            HostedCredentials.serviceURL(environment: environment, infoValue: info)?.absoluteString
        }
        XCTAssertEqual(url([:], "https://jarvis-keys.example.workers.dev"), "https://jarvis-keys.example.workers.dev")
        XCTAssertEqual(url(["JARVIS_CREDENTIALS_URL": "http://127.0.0.1:8787"], "https://a.example"), "http://127.0.0.1:8787")
        XCTAssertEqual(url(["JARVIS_CREDENTIALS_URL": "http://localhost:8787"]), "http://localhost:8787")
        XCTAssertNil(url([:], "http://jarvis-keys.example.workers.dev"))
        XCTAssertNil(url([:], ""))
        XCTAssertNil(url([:]))
        XCTAssertNil(url([:], "not a url"))
    }

    func testConcurrentCallersRegisterOnceAndKeepTheTokenInTheStore() async throws {
        let service = FakeService(), tokens = TokenBox()
        let credentials = hosted(service, tokens: tokens)
        async let first = credentials.installToken()
        async let second = credentials.installToken()
        let both = try await [first, second]
        XCTAssertEqual(both, ["jv1_token1", "jv1_token1"])
        XCTAssertEqual(try tokens.read(), "jv1_token1")
        let again = try await credentials.installToken()
        XCTAssertEqual(again, "jv1_token1")
        let registrations = await service.seen.filter { $0.path == "/base/v1/installs" }
        XCTAssertEqual(registrations.count, 1)
        XCTAssertNil(registrations[0].authorization)
    }

    func testRealtimeSecretCarriesTheInstallTokenAndPinnedModel() async throws {
        let service = FakeService()
        let credential = try await hosted(service, tokens: TokenBox("jv1_stored")).realtimeCredential()
        XCTAssertEqual(credential, RealtimeCredential(key: "ek_fixture", model: "gpt-realtime-fixture"))
        let seen = await service.seen
        XCTAssertEqual(seen, [.init(path: "/base/v1/realtime/client_secret", authorization: "Bearer jv1_stored")])
    }

    func testAForgottenInstallRegistersAgainOnce() async throws {
        let service = FakeService(), tokens = TokenBox("jv1_forgotten")
        await service.setRealtimeReplies([(401, #"{"error":{"code":"unknown_install","message":"This install isn't registered."}}"#)])
        let credential = try await hosted(service, tokens: tokens).realtimeCredential()
        XCTAssertEqual(credential.key, "ek_fixture")
        XCTAssertEqual(try tokens.read(), "jv1_token1")
        let paths = await service.seen.map(\.path)
        XCTAssertEqual(paths, ["/base/v1/realtime/client_secret", "/base/v1/installs", "/base/v1/realtime/client_secret"])
    }

    func testAStaleFailureKeepsAFresherRegistration() async throws {
        let service = FakeService(), tokens = TokenBox("jv1_forgotten")
        await service.forget("jv1_forgotten")
        let credentials = hosted(service, tokens: tokens)
        async let first = credentials.realtimeCredential()
        async let second = credentials.realtimeCredential()
        let keys = try await [first, second].map(\.key)
        XCTAssertEqual(keys, ["ek_fixture", "ek_fixture"])
        XCTAssertEqual(try tokens.read(), "jv1_token1")
        let registrations = await service.seen.filter { $0.path == "/base/v1/installs" }.count
        XCTAssertEqual(registrations, 1, "the second failure must not drop the first one's new token")
    }

    func testARevokedInstallStaysRevokedAndSaysWhy() async throws {
        let service = FakeService(), tokens = TokenBox("jv1_revoked")
        await service.setRealtimeReplies([(403, #"{"error":{"code":"revoked","message":"This Mac's access to Jarvis's service was turned off."}}"#)])
        do {
            _ = try await hosted(service, tokens: tokens).realtimeCredential()
            XCTFail("expected revoked")
        } catch let failure as HostedCredentials.Failure {
            XCTAssertEqual(failure.code, "revoked")
            XCTAssertEqual(failure.localizedDescription, "This Mac's access to Jarvis's service was turned off.")
        }
        XCTAssertEqual(try tokens.read(), "jv1_revoked")
        let count = await service.seen.count
        XCTAssertEqual(count, 1)
    }

    func testAnUnreachableServiceSaysSo() async {
        let credentials = HostedCredentials(baseURL: base, tokenStore: TokenBox(),
                                            transport: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await credentials.realtimeCredential()
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? HostedCredentials.Failure, .unreachable)
        }
    }

    func testHostedConfigNeedsNoKeysAndHidesTheKeyFields() {
        let hosted = config(hosted: hosted(FakeService()))
        XCTAssertTrue(hosted.hostedCredentialsConfigured)
        XCTAssertFalse(hosted.needsKeys)
        XCTAssertFalse(hosted.showsKeyFields)

        let developer = config(hosted: self.hosted(FakeService()), environment: ["OPENAI_API_KEY": "sk-developer"])
        XCTAssertTrue(developer.showsKeyFields, "a typed key stays visible so it can be removed")

        let unhosted = config(hosted: nil)
        XCTAssertFalse(unhosted.hostedCredentialsConfigured)
        XCTAssertTrue(unhosted.needsKeys)
        XCTAssertTrue(unhosted.showsKeyFields)
    }

    func testRoutesUseTheServiceUnlessADeveloperKeyIsSet() async throws {
        let service = FakeService()
        let hosted = config(hosted: hosted(service, tokens: TokenBox("jv1_stored")))
        let realtime = try await hosted.realtimeCredential()
        XCTAssertEqual(realtime, RealtimeCredential(key: "ek_fixture", model: "gpt-realtime-fixture"))
        let jev = try await hosted.jevRoute()
        XCTAssertEqual(jev, ServiceRoute(url: URL(string: "https://keys.example/base/v1/jev")!, bearer: "jv1_stored"))
        let responses = try await hosted.responsesRoute()
        XCTAssertEqual(responses, ServiceRoute(url: URL(string: "https://keys.example/base/v1/responses")!, bearer: "jv1_stored"))
        XCTAssertEqual(hosted.jevEnvironment, ["TYPESAFE_API_KEY": "jv1_stored",
                                               "TYPESAFE_BASE_URL": "https://keys.example/base/v1/jev"])

        let developer = config(hosted: self.hosted(service),
                               environment: ["OPENAI_API_KEY": "sk-developer", "TYPESAFE_API_KEY": "ts-developer"])
        let developerRealtime = try await developer.realtimeCredential()
        XCTAssertEqual(developerRealtime, RealtimeCredential(key: "sk-developer", model: nil))
        let developerJev = try await developer.jevRoute()
        XCTAssertEqual(developerJev, ServiceRoute(url: JevClient.systemOneURL, bearer: "ts-developer"))
        let developerResponses = try await developer.responsesRoute()
        XCTAssertEqual(developerResponses, ServiceRoute(url: TerraClient.endpoint, bearer: "sk-developer"))
        XCTAssertEqual(developer.jevEnvironment, ["TYPESAFE_API_KEY": "ts-developer"])

        let seen = await service.seen.count
        XCTAssertEqual(seen, 1, "only the hosted Realtime secret reached the service")

        let none = config(hosted: nil)
        let noRealtime = try await none.realtimeCredential()
        let noJev = try await none.jevRoute()
        XCTAssertNil(noRealtime)
        XCTAssertNil(noJev)
        XCTAssertEqual(none.jevEnvironment, [:])
    }

    func testKeysSavedInTheKeychainStillWinOverTheService() async throws {
        let service = FakeService()
        let owner = Config(defaults: UserDefaults(suiteName: "hosted-\(UUID().uuidString)")!,
                           keyStore: TokenBox("ts-saved"), openAIKeyStore: TokenBox("sk-saved"),
                           environment: [:], hosted: hosted(service, tokens: TokenBox("jv1_stored")))
        XCTAssertTrue(owner.hostedCredentialsConfigured)
        XCTAssertTrue(owner.showsKeyFields, "saved keys stay visible so they can be removed")

        let realtime = try await owner.realtimeCredential()
        XCTAssertEqual(realtime, RealtimeCredential(key: "sk-saved", model: nil))
        let jev = try await owner.jevRoute()
        XCTAssertEqual(jev, ServiceRoute(url: JevClient.systemOneURL, bearer: "ts-saved"))
        let responses = try await owner.responsesRoute()
        XCTAssertEqual(responses, ServiceRoute(url: TerraClient.endpoint, bearer: "sk-saved"))
        XCTAssertEqual(owner.jevEnvironment, ["TYPESAFE_API_KEY": "ts-saved"])
        let seen = await service.seen.count
        XCTAssertEqual(seen, 0, "no request reaches the service while saved keys are set")
    }

    func testTerraSendsToTheRouteItIsGiven() async throws {
        let route = ServiceRoute(url: URL(string: "https://keys.example/base/v1/responses")!, bearer: "jv1_stored")
        var client = TerraClient(route: { route })
        let sent = LockedBox<URLRequest?>(nil)
        client.transport = { request in
            sent.set(request)
            let body = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"ok\":true}"}]}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let answer = try await client.respond(.init(instructions: "i", text: "t", schemaName: "s", schema: .object([:])))
        XCTAssertEqual(answer, .object(["ok": .bool(true)]))
        XCTAssertEqual(sent.value?.url, route.url)
        XCTAssertEqual(sent.value?.value(forHTTPHeaderField: "Authorization"), "Bearer jv1_stored")
    }

    @MainActor
    func testTheVoiceLaneConnectsWithTheMintedSecretAndItsModel() async throws {
        let wire = EchoWire()
        let requests = LockedBox<[URLRequest]>([])
        let client = RealtimeVoiceClient(wireFactory: { request in
            requests.set(requests.value + [request])
            return wire
        })
        defer { client.teardown() }
        let lane = RealtimeVoiceLane(credential: { RealtimeCredential(key: "ek_fixture", model: "gpt-realtime-fixture") },
                                     client: client)
        try await lane.prepareRealtimeTransport(.manual)
        let request = try XCTUnwrap(requests.value.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ek_fixture")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "model" }?.value, "gpt-realtime-fixture")
    }

    @MainActor
    func testTheVoiceLaneReportsAMissingCredential() async {
        let lane = RealtimeVoiceLane(credential: { nil }, client: RealtimeVoiceClient(wireFactory: { _ in EchoWire() }))
        do {
            try await lane.prepareRealtimeTransport(.manual)
            XCTFail("expected the missing-key error")
        } catch {
            XCTAssertEqual(error.localizedDescription, OutcomeWording.missingVoiceKey)
        }
    }
}

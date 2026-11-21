import Foundation
import XCTest
@testable import Jarvis

/// KAR-75 L10: the month's Live voice, the 80% warning and basic voice.
/// The Worker is faked; nothing leaves the Mac.
@MainActor
final class LiveAllowanceTests: XCTestCase {
    private let renews = Date(timeIntervalSince1970: 1_796_083_200)

    private func status(used: Double, limit: Double? = 18_000, capped: Bool = false, metering: Bool = true,
                        period: String = "2026-11") -> LiveAllowanceStatus {
        LiveAllowanceStatus(metering: metering, tier: "jarvis", period: period, periodEnds: renews,
                            liveSeconds: used, liveSecondsLimit: limit, warnAt: 0.8, capped: capped, tasksLimit: 100)
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "live-allowance-\(UUID().uuidString)")! }

    func testReadsTheWorkersUsageBodyWithTheInstallToken() async throws {
        let sent = LockedBox<URLRequest?>(nil)
        let hosted = HostedLiveAllowance(baseURL: URL(string: "https://keys.example/base")!,
                                         installToken: { "jv1_stored" }, send: { request in
            sent.set(request)
            let body = #"{"metering":true,"tier":"jarvis","period":"2026-11","periodEnds":"2026-12-01T00:00:00.000Z","liveSeconds":14400.5,"liveSecondsLimit":18000,"warnAt":0.8,"capped":false,"tasksLimit":100}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let status = try await hosted.status()
        XCTAssertEqual(status, self.status(used: 14_400.5))
        XCTAssertEqual(status.fractionUsed ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(sent.value?.url?.absoluteString, "https://keys.example/base/v1/usage")
        XCTAssertEqual(sent.value?.httpMethod, "GET")
        XCTAssertEqual(sent.value?.value(forHTTPHeaderField: "Authorization"), "Bearer jv1_stored")

        let unmetered = try LiveAllowanceStatus.decode(Data(#"{"metering":false,"tier":"jarvis","period":"2026-11","periodEnds":"2026-12-01T00:00:00Z","liveSeconds":0,"liveSecondsLimit":null,"warnAt":0.8,"capped":false,"tasksLimit":100}"#.utf8))
        XCTAssertNil(unmetered.fractionUsed)
        XCTAssertNil(LiveAllowance.usedLine(unmetered))
    }

    func testTheWarningShowsOncePerPeriod() {
        let store = defaults()
        let allowance = LiveAllowance(fetch: { self.status(used: 0) }, defaults: store)
        allowance.apply(status(used: 14_000))
        XCTAssertNil(allowance.takeWarning(), "77% is under the warning share")
        allowance.apply(status(used: 14_400))
        XCTAssertEqual(allowance.takeWarning(), "You've used 80% of this month's Live voice. It renews on December 1.")
        allowance.apply(status(used: 16_000))
        XCTAssertNil(allowance.takeWarning(), "once per period")
        let relaunched = LiveAllowance(fetch: { self.status(used: 0) }, defaults: store)
        relaunched.apply(status(used: 16_000))
        XCTAssertNil(relaunched.takeWarning(), "a relaunch keeps the period's warning shown")
        relaunched.apply(status(used: 15_000, period: "2026-12"))
        XCTAssertNotNil(relaunched.takeWarning(), "a new period warns again")
        relaunched.apply(status(used: 18_000, capped: true, period: "2027-01"))
        XCTAssertNil(relaunched.takeWarning(), "at the cap basic voice says it instead")
    }

    func testTheCapTurnsOnBasicVoiceUntilThePeriodEnds() {
        var held: [Bool] = []
        let allowance = LiveAllowance(fetch: { self.status(used: 0) }, defaults: defaults(), onBasicVoice: { held.append($0) })
        allowance.apply(status(used: 17_000))
        XCTAssertEqual(allowance.mode, .live)
        allowance.apply(status(used: 18_000, capped: true))
        XCTAssertEqual(allowance.mode, .basic(until: renews))
        allowance.apply(status(used: 18_000, capped: true))
        allowance.apply(status(used: 0, period: "2026-12"))
        XCTAssertEqual(allowance.mode, .live)
        XCTAssertEqual(held, [true, false], "the paid routes are held once and released at renewal")
        allowance.apply(status(used: 99_000, capped: true, metering: false))
        XCTAssertEqual(allowance.mode, .live, "nothing is capped while metering is off")
    }

    func testTheBrokersLiveLimitRefusalMeansBasicVoice() {
        let allowance = LiveAllowance(fetch: { self.status(used: 0) }, defaults: defaults())
        allowance.apply(status(used: 17_900))
        XCTAssertFalse(allowance.refused(LiveBrokerError(status: 429, code: "rate_limited", message: "slow down")))
        XCTAssertFalse(allowance.refused(URLError(.notConnectedToInternet)))
        XCTAssertEqual(allowance.mode, .live)
        XCTAssertTrue(allowance.refused(LiveBrokerError(status: 429, code: "live_limit", message: "used up")))
        XCTAssertEqual(allowance.mode, .basic(until: renews))
    }

    func testAFailedRefreshKeepsTheLastFigures() async {
        var answer: LiveAllowanceStatus? = status(used: 18_000, capped: true)
        let allowance = LiveAllowance(fetch: {
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }, defaults: defaults())
        await allowance.refresh()
        answer = nil
        await allowance.refresh()
        XCTAssertEqual(allowance.mode, .basic(until: renews))
        XCTAssertEqual(LiveAllowance.usedLine(allowance.status!), "5 h of 5 h used")
        XCTAssertEqual(LiveAllowance.duration(7_830), "2 h 10 min")
        XCTAssertEqual(LiveAllowance.duration(59), "0 min")
    }

    func testBasicVoiceHoldsTheServicesPaidRoutes() async throws {
        let config = Config(defaults: defaults(), keyStore: NoKeys(), openAIKeyStore: NoKeys(), environment: [:],
                            hosted: HostedCredentials(baseURL: URL(string: "https://keys.example/base")!,
                                                      tokenStore: OneToken(), transport: { _ in throw URLError(.cancelled) }))
        let jev = try await config.jevRoute()
        XCTAssertNotNil(jev)
        config.basicVoice = true
        let heldJev = try await config.jevRoute()
        let heldResponses = try await config.responsesRoute()
        XCTAssertNil(heldJev)
        XCTAssertNil(heldResponses)
        XCTAssertEqual(config.jevEnvironment, [:])

        let developer = Config(defaults: defaults(), keyStore: NoKeys(), openAIKeyStore: NoKeys(),
                               environment: ["TYPESAFE_API_KEY": "ts-developer"], hosted: nil)
        developer.basicVoice = true
        let developerJev = try await developer.jevRoute()
        XCTAssertEqual(developerJev?.bearer, "ts-developer", "a developer's own key is never capped")
    }

    func testBasicVoiceRunsCommandsAndHoldsConversationForLive() async {
        var ran: [String] = [], spoken: [String] = [], shown: [[String]] = []
        var speaks = true
        let turn = BasicVoiceTurn(run: { text in
            ran.append(text)
            return VoiceToolResult(status: VoiceToolResult.Status.ok, say: "Opened Calculator.").encoded()
        }, speak: { spoken.append($0) }, show: { shown.append($0) }, speaksReplies: { speaks })

        await turn.handle("open Calculator", until: renews)
        XCTAssertEqual(ran, ["open Calculator"])
        XCTAssertEqual(spoken, ["Opened Calculator."])

        let held = await turn.handle("what is the capital of Peru", until: renews)
        XCTAssertEqual(held, "That needs Live voice, which is back on December 1. Commands and typing still work.")
        XCTAssertEqual(ran, ["open Calculator"], "a question never reaches the spine in basic voice")

        speaks = false
        await turn.handle("open Calculator", until: renews)
        XCTAssertEqual(spoken.count, 2, "with Say replies out loud off nothing more is spoken")
        XCTAssertEqual(shown, [["Opened Calculator."]])
    }
}

private struct NoKeys: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

private struct OneToken: APIKeyStore {
    func read() throws -> String? { "jv1_stored" }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

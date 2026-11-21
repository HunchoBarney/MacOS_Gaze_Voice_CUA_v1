import Foundation

/// `GET /v1/usage` on the credential Worker (KAR-75 L10): this Mac's tier and
/// how much of the month's Live voice it has used. Live seconds are weighted
/// by the Worker: a Standby second counts for less than a talking one.
struct LiveAllowanceStatus: Decodable, Equatable, Sendable {
    let metering: Bool
    let tier: String
    let period: String
    let periodEnds: Date
    let liveSeconds: Double
    let liveSecondsLimit: Double?
    let warnAt: Double
    let capped: Bool
    let tasksLimit: Int?

    /// The share of the month's Live voice used, 0–1, or nil when nothing caps it.
    var fractionUsed: Double? {
        guard metering, let limit = liveSecondsLimit, limit > 0 else { return nil }
        return min(liveSeconds / limit, 1)
    }

    static func decode(_ data: Data) throws -> LiveAllowanceStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "periodEnds isn't an ISO 8601 date"))
            }
            return date
        }
        return try decoder.decode(LiveAllowanceStatus.self, from: data)
    }
}

/// Reads `GET /v1/usage` with the install token, like `HostedLiveSessions`.
struct HostedLiveAllowance: Sendable {
    let baseURL: URL
    let installToken: @Sendable () async throws -> String
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    func status() async throws -> LiveAllowanceStatus {
        var request = URLRequest(url: baseURL.appending(path: "v1/usage"))
        request.setValue("Bearer \(try await installToken())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LiveBrokerError(status: status, code: nil, message: "The voice service answered \(status).")
        }
        return try LiveAllowanceStatus.decode(data)
    }
}

/// Whether this Mac may open GPT-Live sessions this month (plan §10). Once
/// the month's Live voice is used up, Jarvis keeps working in basic voice
/// until the period ends: on-device transcription, the same spine for
/// commands and typing, and no paid calls. `onBasicVoice` tells the rest of
/// the app, which holds hosted Jev and Responses calls while it's true.
@MainActor
final class LiveAllowance: ObservableObject {
    enum Mode: Equatable {
        case live
        case basic(until: Date)
    }

    static let shared: LiveAllowance = {
        let hosted = Config.shared.hosted
        return LiveAllowance(fetch: {
            guard let hosted else { throw LiveBrokerError(status: 0, code: nil, message: "No hosted voice service.") }
            return try await HostedLiveAllowance(baseURL: hosted.baseURL,
                                                 installToken: { try await hosted.installToken() }).status()
        }, onBasicVoice: { Config.shared.basicVoice = $0 })
    }()

    @Published private(set) var status: LiveAllowanceStatus?
    @Published private(set) var mode: Mode = .live {
        didSet { if mode != oldValue { onBasicVoice(mode != .live) } }
    }

    private let fetch: () async throws -> LiveAllowanceStatus
    private let defaults: UserDefaults
    private let onBasicVoice: (Bool) -> Void
    private static let warnedKey = "live.allowance.warnedPeriod"

    init(fetch: @escaping () async throws -> LiveAllowanceStatus,
         defaults: UserDefaults = .standard,
         onBasicVoice: @escaping (Bool) -> Void = { _ in }) {
        self.fetch = fetch
        self.defaults = defaults
        self.onBasicVoice = onBasicVoice
    }

    /// Reads the Worker's figures. A failed read keeps the last ones.
    func refresh() async {
        guard let status = try? await fetch() else { return }
        apply(status)
    }

    func apply(_ status: LiveAllowanceStatus) {
        self.status = status
        mode = status.metering && status.capped ? .basic(until: status.periodEnds) : .live
    }

    /// Whether `error` is the broker refusing a new session because this
    /// month's Live voice is used up; if so Jarvis is in basic voice now.
    func refused(_ error: Error) -> Bool {
        guard let refusal = error as? LiveBrokerError, refusal.code == "live_limit" else { return false }
        mode = .basic(until: status?.periodEnds ?? Self.nextPeriod(after: Date()))
        return true
    }

    /// The one warning line for crossing the warning share, at most once a period.
    func takeWarning() -> String? {
        guard let status, !status.capped, let used = status.fractionUsed, used >= status.warnAt,
              defaults.string(forKey: Self.warnedKey) != status.period else { return nil }
        defaults.set(status.period, forKey: Self.warnedKey)
        return "You've used \(Int((used * 100).rounded(.down)))% of this month's Live voice. It renews on \(Self.day(status.periodEnds))."
    }

    static func basicVoiceLine(until: Date) -> String {
        "This month's Live voice is used up, so Jarvis is in basic voice until \(day(until)). Commands and typing still work."
    }

    static func needsLiveLine(until: Date) -> String {
        "That needs Live voice, which is back on \(day(until)). Commands and typing still work."
    }

    /// "2 h 10 min of 5 h used", for the usage section.
    static func usedLine(_ status: LiveAllowanceStatus) -> String? {
        guard let limit = status.liveSecondsLimit, status.metering else { return nil }
        return "\(duration(status.liveSeconds)) of \(duration(limit)) used"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded(.down))
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The period ends at midnight UTC, so the day is named in UTC too.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: date)
    }

    static func nextPeriod(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let month = calendar.dateInterval(of: .month, for: date)!
        return month.end
    }
}

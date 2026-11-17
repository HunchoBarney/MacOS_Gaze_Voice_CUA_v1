import Combine
import Foundation

/// A minimal per-day model-call counter — a counter, not a system.
///
/// Counts are bumped off the same observable streams the ledger reads
/// (no lane changes required):
///   - `realtimeTurn` — each `.finishing` capture edge: one committed
///     audio turn on the realtime lane.
///   - `responseCreate` — each `.heard` feed entry: a turn that carried a
///     `computer_command` (voice and typed turns alike). Pure reply turns
///     undercount — noted, acceptable for a spend gauge.
///   - `systemOneRTT` — each "round N:" feed line: one Jev chooser RTT.
///
/// The sidecar lives at `~/Library/Application Support/JevVoice/spend.json`:
/// `{ "days": { "2026-10-14": { "realtime_turn": 3, ... } } }`, pruned to
/// the trailing ~40 days. Writes coalesce 250ms so a burst of rounds is
/// one file write, not one per line.
@MainActor
final class SpendCounter: ObservableObject {
    static let shared = SpendCounter()

    enum Kind: String, Codable, CaseIterable {
        case realtimeTurn = "realtime_turn"
        case responseCreate = "response_create"
        case systemOneRTT = "system_one_rtt"
    }

    /// Today's total across all kinds — the Settings read-out.
    @Published private(set) var today = 0
    /// Per-kind counts for today — surfaced in a hint line/tests.
    @Published private(set) var todayByKind: [Kind: Int] = [:]

    private var counts: [String: [String: Int]] = [:]   // dayKey → kind raw → n
    private var dayKey: String
    private let fileURL: URL
    private let now: () -> Date
    private var writeScheduled = false
    private let ioQueue = DispatchQueue(label: "com.chriswozniczek.jevvoice.spendcounter")
    private var cancellables: Set<AnyCancellable> = []
    private var seenFeedIDs: Set<UUID> = []
    private var lastCapture: VoiceController.CaptureState = .idle
    private var attached = false

    /// Only this many day buckets persist — a year of counts would still
    /// be a small file; the bound is just tidiness.
    static let keptDays = 40

    init(fileURL: URL? = nil, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL ?? Self.defaultURL()
        self.now = now
        self.dayKey = Self.dayKey(for: now())
        self.counts = Self.load(url: self.fileURL)
        let day = counts[dayKey] ?? [:]
        self.todayByKind = Self.byKind(day)
        self.today = Self.total(day)
    }

    static func defaultURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice", isDirectory: true)
            .appendingPathComponent("spend.json")
    }

    // MARK: - Counting

    /// Bump one kind for the current day. Date rollover re-keys rather
    /// than carrying midnight stragglers onto yesterday.
    func bump(_ kind: Kind) {
        let key = Self.dayKey(for: now())
        if key != dayKey { dayKey = key }
        var day = counts[key] ?? [:]
        day[kind.rawValue, default: 0] += 1
        counts[key] = day
        if counts.count > Self.keptDays {
            let keep = Set(counts.keys.sorted().suffix(Self.keptDays))
            counts = counts.filter { keep.contains($0.key) }
        }
        todayByKind = Self.byKind(day)
        today = Self.total(day)
        scheduleWrite()
    }

    /// Count for a specific kind today — test/affordance seam.
    func count(_ kind: Kind) -> Int { todayByKind[kind] ?? 0 }

    /// The raw day buckets, for tests asserting the persisted shape.
    var dayCounts: [String: [String: Int]] { counts }

    // MARK: - Wiring

    /// Attach to the controller's existing streams — idempotent.
    func attach(controller: VoiceController) {
        guard !attached else { return }
        attached = true

        seenFeedIDs = Set(controller.cua.feed.entries.map(\.id))
        controller.cua.feed.$entries
            .sink { [weak self] entries in
                guard let self else { return }
                for entry in entries where !self.seenFeedIDs.contains(entry.id) {
                    self.seenFeedIDs.insert(entry.id)
                    switch entry.kind {
                    case .heard:
                        self.bump(.responseCreate)
                    case .dispatch where entry.text.range(
                        of: #"^round\s+\d+:"#, options: .regularExpression) != nil:
                        self.bump(.systemOneRTT)
                    default:
                        break
                    }
                }
                self.seenFeedIDs.formIntersection(Set(entries.map(\.id)))
            }
            .store(in: &cancellables)

        lastCapture = controller.captureState
        controller.$captureState
            .sink { [weak self] state in
                guard let self else { return }
                if state == .finishing, self.lastCapture != .finishing {
                    self.bump(.realtimeTurn)
                }
                self.lastCapture = state
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        ioQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.writeScheduled = false
                self.flush()
            }
        }
    }

    /// Synchronous write — tests assert the file right after calling.
    /// Safe to call on a whim; the coalescer keeps production calls rare.
    func flush() { Self.save(counts, to: fileURL) }

    private static func load(url: URL) -> [String: [String: Int]] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = root["days"] as? [String: [String: Int]]
        else { return [:] }
        return days
    }

    private static func save(_ counts: [String: [String: Int]], to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["days": counts], options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Day math

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func byKind(_ day: [String: Int]) -> [Kind: Int] {
        var out: [Kind: Int] = [:]
        for kind in Kind.allCases {
            if let n = day[kind.rawValue] { out[kind] = n }
        }
        return out
    }

    private static func total(_ day: [String: Int]) -> Int {
        day.values.reduce(0, +)
    }
}

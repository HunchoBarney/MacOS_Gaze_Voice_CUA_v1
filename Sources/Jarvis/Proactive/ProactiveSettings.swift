import Combine
import Foundation

/// Proactivity's persisted state, in an injected defaults suite so tests
/// never touch the real one. Reading notification banners (D4) is off
/// until onboarding asks.
@MainActor
final class ProactiveSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var level: ProactiveLevel {
        didSet {
            defaults.set(level.rawValue, forKey: Keys.level)
            learning = ProactiveLearning()
        }
    }
    @Published var readNotificationBanners: Bool {
        didSet { defaults.set(readNotificationBanners, forKey: Keys.banners) }
    }
    /// People whose urgent messages may be spoken. L8 memory can feed this
    /// list later; for now the person edits it in Settings.
    @Published var importantPeople: [String] {
        didSet { defaults.set(importantPeople, forKey: Keys.people) }
    }
    /// Senders the person asked to hear from: "tell me when Dana replies".
    @Published private(set) var watches: [String] {
        didSet { defaults.set(watches, forKey: Keys.watches) }
    }
    var learning: ProactiveLearning {
        didSet { save(learning, Keys.learning) }
    }
    var budget: ProactiveBudget {
        didSet { save(budget, Keys.budget) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        level = defaults.string(forKey: Keys.level).flatMap(ProactiveLevel.init(rawValue:)) ?? .normal
        readNotificationBanners = defaults.object(forKey: Keys.banners) as? Bool ?? false
        importantPeople = defaults.stringArray(forKey: Keys.people) ?? []
        watches = defaults.stringArray(forKey: Keys.watches) ?? []
        learning = Self.load(ProactiveLearning.self, defaults, Keys.learning) ?? ProactiveLearning()
        budget = Self.load(ProactiveBudget.self, defaults, Keys.budget) ?? ProactiveBudget()
    }

    func watch(_ sender: String) {
        let name = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !watches.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        watches.append(name)
    }

    func unwatch(_ sender: String) {
        watches.removeAll { $0.caseInsensitiveCompare(sender) == .orderedSame }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private enum Keys {
        static let level = "proactive.level"
        static let banners = "proactive.readNotificationBanners"
        static let people = "proactive.importantPeople"
        static let watches = "proactive.watches"
        static let learning = "proactive.learning"
        static let budget = "proactive.budget"
    }
}

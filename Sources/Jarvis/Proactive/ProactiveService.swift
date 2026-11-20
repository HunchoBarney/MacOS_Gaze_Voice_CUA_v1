import AppKit
import Combine
import Foundation

extension ProactiveSettings {
    static let shared = ProactiveSettings(defaults: .standard)
}

/// What a spoken request becomes when proactivity answers it instead of
/// the task loop: a line to say, or a request to run as if it was spoken.
enum ProactiveIntercept: Equatable {
    case say(String)
    case request(String)
}

/// Runs proactivity while `voice.live` is on: polls the sources, ticks the
/// engine, shows the safety card and answers "what's up", "what did I
/// miss", "tell me when Dana replies" and replies to a spoken alert.
@MainActor
final class ProactiveService {
    static let tickInterval: TimeInterval = 2
    static let eventKitInterval: TimeInterval = 30
    static let safetyInterval: TimeInterval = 10
    static let bannerInterval: TimeInterval = 3

    let settings: ProactiveSettings
    let engine: ProactiveEngine
    private let eventKit = EventKitSource()
    private let card: ProactiveCardPanel
    private var timers: [Timer] = []
    private(set) var running = false

    /// Wired by the app: the person is speaking or a turn is open, and
    /// Jarvis is speaking.
    var userTalking: () -> Bool = { false }
    var jarvisSpeaking: () -> Bool = { false }

    init(speech: any SpeechSynthesizing, settings: ProactiveSettings = .shared) {
        self.settings = settings
        let probe = ProactiveContextBox()
        engine = ProactiveEngine(settings: settings, voice: OnDeviceAlertVoice(output: speech),
                                 context: { probe.read() })
        card = ProactiveCardPanel(engine: engine)
        probe.service = self
    }

    func start() {
        guard !running else { return }
        running = true
        schedule(Self.tickInterval) { $0.engine.tick() }
        schedule(Self.eventKitInterval, now: true) { $0.pollEventKit() }
        schedule(Self.safetyInterval, now: true) { $0.pollSafety() }
        schedule(Self.bannerInterval) { $0.pollBanners() }
    }

    func stop() {
        running = false
        timers.forEach { $0.invalidate() }
        timers = []
        engine.dismissCard()
    }

    private func schedule(_ interval: TimeInterval, now: Bool = false, _ work: @escaping @MainActor (ProactiveService) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
        if now { work(self) }
    }

    // MARK: - Sources

    private func pollEventKit() {
        let now = Date()
        engine.submit(CalendarRules.alerts(eventKit.events(now: now), now: now))
        Task { [weak self] in
            guard let self else { return }
            let reminders = await self.eventKit.reminders(now: now)
            guard self.running else { return }
            self.engine.submit(ReminderRules.alerts(reminders, now: Date()))
        }
    }

    private func pollSafety() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = front.bundleIdentifier
        let onCall = OtherMicrophoneUse.active()
        let isBrowser = bundleID.map(SafetyRules.browsers.contains) ?? false
        guard isBrowser || (onCall && bundleID.map { SafetyRules.remoteAccess[$0] != nil } == true) else { return }
        Task { [weak self] in
            var limits = ScreenContext.Limits.standard
            limits.maxNodes = 800
            limits.deadline = .milliseconds(250)
            let page = isBrowser ? await ScreenContext.readFocused(limits: limits) : nil
            guard let self, self.running else { return }
            self.engine.submit(SafetyRules.alerts(page: page, frontBundleID: bundleID, frontAppName: front.localizedName,
                                                  onCall: onCall, now: Date()))
        }
    }

    private func pollBanners() {
        guard settings.readNotificationBanners,
              let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        Task { [weak self] in
            let trees = await ScreenContext.windowTrees(pid: center.processIdentifier)
            guard let self, self.running else { return }
            let banners = trees.flatMap(BannerRules.banners(from:))
            guard !banners.isEmpty else { return }
            let alerts = BannerRules.alerts(banners, important: self.settings.importantPeople,
                                            watches: self.settings.watches, now: Date())
            self.engine.submit(alerts)
            for alert in alerts where alert.category == .awaitedReply {
                for name in self.settings.watches where BannerRules.matches(alert.sender ?? "", [name]) {
                    self.settings.unwatch(name)
                }
            }
        }
    }

    // MARK: - Spoken requests

    /// nil leaves the utterance to the task loop.
    func intercept(_ utterance: String) -> ProactiveIntercept? {
        guard running else { return nil }
        let eventKit = self.eventKit
        return ProactiveCommands(engine: engine, settings: settings,
                                 completeReminder: { eventKit.complete(reminder: $0) }).intercept(utterance)
    }
}

/// The spoken requests proactivity answers: "what's up", "what did I
/// miss", "tell me when Dana replies", and a reply to a spoken alert.
@MainActor
struct ProactiveCommands {
    let engine: ProactiveEngine
    let settings: ProactiveSettings
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var completeReminder: @MainActor (String) -> Bool

    private static let whatsUp: Set<String> = ["what's up", "whats up", "what is up", "anything new", "any updates"]
    private static let missed: Set<String> = [
        "what did i miss", "what have i missed", "what did i miss today", "catch me up", "anything i missed",
    ]
    private static let wakeLeads = ["hey jarvis", "okay jarvis", "ok jarvis", "jarvis"]
    private static let watchPattern = try! NSRegularExpression(
        pattern: #"^(?:tell|let) me (?:know )?when (.+?) (?:replies|writes back|messages me|texts me|answers|gets back to me)$"#)

    /// nil leaves the utterance to the task loop.
    func intercept(_ utterance: String) -> ProactiveIntercept? {
        var spoken = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lead = Self.wakeLeads.first(where: { spoken.lowercased().hasPrefix($0) }) {
            spoken = String(spoken.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
        }
        let phrase = spoken.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
        if engine.awaiting != nil {
            switch engine.handleReply(spoken) {
            case .ignored, .converse: break
            case .declined: return .say("Okay.")
            case .snoozed: return .say("Okay, later.")
            case .accepted(let alerts): return accept(alerts)
            }
        }
        if Self.whatsUp.contains(phrase) { return .say(engine.whatsUp()) }
        if Self.missed.contains(phrase) { return .say(engine.whatDidIMiss()) }
        if let match = Self.watchPattern.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
           let nameRange = Range(match.range(at: 1), in: phrase) {
            let name = String(phrase[nameRange]).trimmingCharacters(in: .whitespaces)
            settings.watch(name)
            return .say("I'll tell you when \(name) replies.")
        }
        return nil
    }

    private func accept(_ alerts: [ProactiveAlert]) -> ProactiveIntercept {
        guard alerts.count == 1, let alert = alerts.first else {
            return .say(alerts.map(\.sentence).joined(separator: " "))
        }
        switch alert.action {
        case .openURL(let url):
            openURL(url)
            return .say("Opening it.")
        case .request(let request):
            return .request(request)
        case .completeReminder(let id):
            return .say(completeReminder(id) ? "Done." : "I couldn't mark it done.")
        case .read(let text):
            return .say(text)
        case nil:
            return .say("Okay.")
        }
    }
}

/// Lets the engine's context closure reach the service after init.
@MainActor
private final class ProactiveContextBox {
    weak var service: ProactiveService?

    func read() -> ProactiveContext {
        ProactiveContextProbe.read(userTalking: service?.userTalking() ?? false,
                                   jarvisSpeaking: service?.jarvisSpeaking() ?? false)
    }
}

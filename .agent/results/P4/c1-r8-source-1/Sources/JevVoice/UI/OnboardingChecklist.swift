import SwiftUI

/// First-run setup checklist — the card that makes "nothing works yet"
/// legible: what Jev still needs, one fix button per row, and a natural
/// "try it" prompt per unlock. No verb grammar sheet — the prompts read
/// like things you'd say to a person, not a command reference.
///
/// State is probe-driven: `refresh()` re-reads each source (permissions,
/// the tracker host, the local-models directory) so a grant landing in
/// System Settings flips its row on the next poll. Probes are injectable
/// — tests drive the transitions without TCC or a real tracker.
@MainActor
final class OnboardingChecklistModel: ObservableObject {
    enum RowID: String, CaseIterable, Identifiable {
        case microphone, accessibility, screenRecording, tracker, localModels
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let id: RowID
        let title: String
        /// What the grant buys, one clause — "to hear you when you hold Fn".
        let detail: String
        /// The natural prompt this row unlocks — shown, never a grammar list.
        let tryIt: String?
        /// Button label for the fix affordance; nil = nothing to press
        /// (the row resolves itself or is waiting on a not-yet-landed lane).
        var fixLabel: String?
        var done = false
    }

    @Published private(set) var rows: [Row] = OnboardingChecklistModel.makeRows()
    /// "Set up later" — persisted; the card stays gone until reset.
    @Published var dismissed: Bool {
        didSet { defaults.set(dismissed, forKey: Self.dismissedKey) }
    }

    /// All rows green — the card retires itself.
    var allClear: Bool { rows.allSatisfy(\.done) }
    /// Whether the card shows at all.
    var visible: Bool { !dismissed && !allClear }
    /// The try-it line for the first unfinished row — the card's "what to
    /// do once this works" hint.
    var pendingTryIt: String? { rows.first { !$0.done }?.tryIt }

    nonisolated static let dismissedKey = "onboardingChecklistDismissed"

    // MARK: - Probes (production defaults; tests inject)

    var microphoneGranted: () -> Bool = { Permission.microphone.isGranted }
    var accessibilityGranted: () -> Bool = { Permission.accessibility.isGranted }
    var screenRecordingGranted: () -> Bool = { Permission.screenRecording.isGranted }
    var trackerEnabled: () -> Bool = { Config.shared.gazeTracking }
    var trackerRunning: () async -> Bool = { await TrackerHost.shared.state == .running }
    /// Local speech/chooser models — the Intelligence lane's download is
    /// pending; the probe reads the support dir it will populate.
    var localModelsReady: () -> Bool = { OnboardingChecklistModel.localModelsPresent() }

    // MARK: - Fix actions (production defaults; tests inject)

    var requestMicrophone: () async -> Void = { await Permission.microphone.request() }
    var requestAccessibility: () async -> Void = { await Permission.accessibility.request() }
    var requestScreenRecording: () async -> Void = { await Permission.screenRecording.request() }
    var enableTracker: () -> Void = { Config.shared.gazeTracking = true }
    /// Runs after any fix so the shell re-reads permissions/input state.
    var afterFix: () -> Void = {}

    private let defaults: UserDefaults

    /// Nonisolated so `@StateObject` view initializers (which run
    /// nonisolated) can construct the model — it touches only stored
    /// properties and takes no actor state.
    nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._dismissed = Published(initialValue: defaults.bool(forKey: Self.dismissedKey))
    }

    private nonisolated static func makeRows() -> [Row] {
        [
            Row(id: .microphone,
                title: "Microphone",
                detail: "to listen when you speak",
                tryIt: "try asking to open an app",
                fixLabel: "Allow"),
            Row(id: .accessibility,
                title: "Accessibility",
                detail: "to control apps on your Mac",
                tryIt: "try asking to scroll the page",
                fixLabel: "Allow"),
            Row(id: .screenRecording,
                title: "Screen Recording",
                detail: "to understand visual controls on screen",
                tryIt: nil,
                fixLabel: "Open Settings"),
            Row(id: .tracker,
                title: "Eye tracking",
                detail: "so “click this” knows where you're looking",
                tryIt: "try: look at a button and say “click this”",
                fixLabel: "Enable"),
            Row(id: .localModels,
                title: "On-device speech models",
                detail: "must be ready before listening can start",
                tryIt: nil,
                fixLabel: nil),
        ]
    }

    /// Re-read every probe — cheap; safe to call on a poll.
    func refresh() async {
        let trackerUp = await trackerRunning()
        for index in rows.indices {
            switch rows[index].id {
            case .microphone: rows[index].done = microphoneGranted()
            case .accessibility: rows[index].done = accessibilityGranted()
            case .screenRecording: rows[index].done = screenRecordingGranted()
            case .tracker: rows[index].done = trackerEnabled() && trackerUp
            case .localModels: rows[index].done = localModelsReady()
            }
        }
    }

    /// Run the row's fix, then refresh so the row repaints honestly —
    /// a grant that didn't land stays undone rather than optimistically
    /// flipping.
    func fix(_ id: RowID) {
        switch id {
        case .microphone:
            Task { await requestMicrophone(); afterFix(); await refresh() }
        case .accessibility:
            Task { await requestAccessibility(); afterFix(); await refresh() }
        case .screenRecording:
            Task { await requestScreenRecording(); afterFix(); await refresh() }
        case .tracker:
            enableTracker()
            afterFix()
            Task { await refresh() }
        case .localModels:
            break // nothing to press — see the row's note
        }
    }

    /// `~/Library/Application Support/JevVoice/models/` with anything in
    /// it counts as downloaded — the on-device lane owns what lands there.
    static func localModelsPresent(
        directory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JevVoice/models", isDirectory: true)
    ) -> Bool {
        guard let directory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil)
        else { return false }
        return !contents.isEmpty
    }
}

/// The card itself — rows with status glyphs and fix buttons, one
/// try-it line, and a dismiss affordance. Renders nothing once the
/// model says `visible == false` (all clear, or "set up later").
struct OnboardingChecklistCard: View {
    @StateObject private var model = OnboardingChecklistModel()
    /// Lets the shell re-read permissions/input after a fix lands.
    var afterFix: () -> Void = {}

    var body: some View {
        if model.visible {
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Getting started", systemImage: "checklist").font(.headline)
                        Spacer()
                        Button("Set up later") { model.dismissed = true }
                            .controlSize(.small)
                    }
                    ForEach(model.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(row.done ? Color.mint : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.callout)
                                Text(row.done ? "ready" : row.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !row.done, let fixLabel = row.fixLabel {
                                Button(fixLabel) { model.fix(row.id) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    if let tryIt = model.pendingTryIt {
                        Text(tryIt).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { model.afterFix = afterFix }
            .task {
                // Poll while the card is up — TCC grants land from System
                // Settings asynchronously; a row must not need a reopen.
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}

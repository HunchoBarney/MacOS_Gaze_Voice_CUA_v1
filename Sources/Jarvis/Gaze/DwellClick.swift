import Foundation

/// B5 — the dwell auto-click policy and engine. `gaze.dwellAutoClick`
/// carries the plan's pinned vocabulary — off / safe / all, default
/// `safe`: `safe` fires only on kinds that can carry a verified or
/// plainly benign actuation (real AX buttons/links, menu items, traffic
/// lights); `all` adds the window floor and the OCR floor. The deny
/// list is a wall, not a suggestion — nothing on it fires regardless
/// of mode, and the per-app exemptions let a user take a whole app out
/// of the pool. Agent cursors and overlay chips are never actuated:
/// cursors are observability chrome, and chips resolve through the
/// overlay's own 500ms dwell pick (two engines on one dwell would
/// double-fire).
struct DwellPolicy: Sendable, Equatable {
    enum Mode: String, Sendable {
        case off, safe, all
    }

    var mode: Mode
    /// Per-app exemptions — matched against the candidate's appName,
    /// lowered. A user can take a whole app out of dwell's reach.
    var deniedApps: Set<String>
    /// The learned per-user multiplier — Majaranta's adaptation:
    /// confirmed commits shrink the delay toward fluency; aborted
    /// holds (the user looked away rather than letting it fire) grow
    /// it back.
    var userMultiplier: Double

    static let baseDelay: TimeInterval = 0.6
    static let fastDelay: TimeInterval = 0.4
    static let minDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 1.8
    /// Softmax share the incumbent needs before the fast tier applies —
    /// a contested winner waits the full base, never the fast path.
    static let dominantShare = 0.7

    /// Kinds no mode ever actuates.
    static let neverKinds: Set<IntentCandidate.Kind> = [.agentCursor, .chip]

    /// `safe` reaches only kinds with a verified or plainly-benign
    /// actuation — real AX/DOM/menu/traffic-light controls. `all` adds
    /// the OCR floor and the window-blind click.
    static let safeKinds: Set<IntentCandidate.Kind> = [
        .axElement, .trafficLight, .dom, .menuBar
    ]

    /// The deny list — a label or role hit means voice/Fn only, forever.
    /// Mirrors CuaPolicy's consequential vocabulary plus the pinned
    /// additions (secure fields, close controls, sign-out); separators
    /// are normalized the same way so "force-quit" can't sneak by.
    static let deniedTokens: [String] = [
        "delete", "trash", "remove", "erase", "eject", "format", "discard",
        "overwrite", "empty", "wipe", "purchase", "buy", "checkout", "pay",
        "subscribe", "order", "send", "submit", "post", "publish", "reply",
        "quit", "sign out", "log out", "restart", "shut down", "close",
        "decline", "block", "unsubscribe", "report", "end call",
        "disconnect", "destroy", "force quit", "reset",
        // keep in sync with CuaPolicy.deniedPatterns — the model loop
        // denies these phrases; dwell's wall must read the same wall.
        "empty trash", "erase all content", "erase disk", "erase this mac",
        "delete permanently", "permanently delete", "format disk",
        "factory reset", "reset all settings", "transfer money",
        "wire transfer", "send payment", "purchase now", "buy now",
        "place order", "confirm purchase", "pay now", "delete account",
        "close account", "remove device", "allow remote access",
        "share my screen", "turn off filevault", "disable sip",
        "enter recovery", "rm -rf", "mkfs", ":(){",
    ]

    /// Whether a committed dwell may actuate this candidate. Mode, kind,
    /// app exemption, and the deny list all gate; ambiguity is handled
    /// upstream (a contested winner never holds long enough to fire).
    func allows(_ c: IntentCandidate) -> Bool {
        guard mode != .off, !Self.neverKinds.contains(c.kind) else { return false }
        if mode == .safe && !Self.safeKinds.contains(c.kind) { return false }
        if let app = c.appName, deniedApps.contains(app.lowercased()) { return false }
        let role = c.role.lowercased()
        // Secure fields are voice/Fn only — a parked eye on a password
        // box must never type, click, or submit into it.
        if role.contains("secure") { return false }
        // The close and fullscreen traffic lights are destructive /
        // disruptive — the id carries the kind so a renamed button
        // can't slip past the label check.
        if c.kind == .trafficLight,
           c.id.hasSuffix(":close") || c.id.hasSuffix(":fullscreen") {
            return false
        }
        // The corpus is every context the candidate carries — a
        // "Confirm delete" window title or a wire-transfer URL denies
        // just as hard as the button's own label.
        let corpus = Self.normalized(
            ([c.label, c.role]
             + [c.appName, c.windowTitle, c.url].compactMap { $0 })
                .joined(separator: " "))
        return !Self.deniedTokens.contains { token in
            let t = Self.normalized(token)
            // A token that normalizes to nothing can't deny everything.
            return !t.isEmpty && corpus.contains(t)
        }
    }

    /// Hold seconds before a permitted dwell commits —
    /// f(posterior share × criticality × learned multiplier). A dominant
    /// share on a clickable role reads as a confident, benign commit and
    /// earns the fast end of the band.
    func delay(for c: IntentCandidate, share: Double) -> TimeInterval {
        var base = Self.baseDelay
        if share >= Self.dominantShare, c.clickabilityPrior >= 1.3 {
            base = Self.fastDelay
        }
        return min(Self.maxDelay, max(Self.minDelay, base * userMultiplier))
    }

    /// A landed actuation — the delay walks toward the user's fluency.
    mutating func recordCommit() {
        userMultiplier = max(0.75, userMultiplier * 0.96)
    }
    /// A real hold that ended without firing reads as "the fire was too
    /// eager or unwanted" — the delay walks back up.
    mutating func recordAbort() {
        userMultiplier = min(1.6, userMultiplier * 1.05)
    }

    /// Deny-match normalization — lowercased, every non-alphanumeric
    /// becomes a space, same shape CuaPolicy uses so "sign-out" matches
    /// "sign out" and "close" can't hide inside punctuation. Format
    /// scalars (zero-width joiners, bidi marks) vanish outright so a
    /// "dele{ZWSP}te" split by a ZWSP still matches; a soft hyphen counts
    /// as the separator it renders as; and the obvious lookalikes
    /// (leet digits, Cyrillic homoglyphs) fold to ASCII.
    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { s -> Character? in
            if s == "\u{00AD}" { return " " }
            guard s.properties.generalCategory != .format else { return nil }
            if let folded = Self.confusables[s] { return folded }
            return CharacterSet.alphanumerics.contains(s) ? Character(s) : " "
        }.reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// The obvious lookalikes — a Cyrillic "а" or a leet "0" can't
    /// dress a denied label up as safe. Deliberately small: this is a
    /// wall, not a font forensics kit.
    private static let confusables: [Unicode.Scalar: Character] = [
        "0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t",
        "@": "a", "$": "s",
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o",
        "\u{0440}": "p", "\u{0441}": "c", "\u{0445}": "x",
        "\u{0443}": "y", "\u{0456}": "i", "\u{0458}": "j",
        "\u{04BB}": "h", "\u{0455}": "s",
    ]

    // MARK: Persistence

    /// UserDefaults keys — the product contract; a Settings surface for
    /// the toggle belongs to a later lane.
    static let modeKey = "gaze.dwellAutoClick"
    static let explicitOptInKey = "gaze.dwellExplicitOptIn"
    static let deniedAppsKey = "gaze.dwellDeniedApps"
    static let multiplierKey = "gaze.dwellMultiplier"

    static func load(from defaults: UserDefaults = .standard) -> DwellPolicy {
        let stored = Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .off
        let optedIn = defaults.string(forKey: explicitOptInKey) == "explicit-v1"
        let mode: Mode = stored == .all || optedIn ? stored : .off
        let denied = Set((defaults.stringArray(forKey: deniedAppsKey) ?? [])
            .map { $0.lowercased() })
        let raw = defaults.object(forKey: multiplierKey) as? Double ?? 1
        return DwellPolicy(mode: mode, deniedApps: denied,
                           userMultiplier: min(1.6, max(0.75, raw)))
    }

    func save(to defaults: UserDefaults = .standard) {
        if mode == .off {
            defaults.removeObject(forKey: Self.explicitOptInKey)
        } else {
            defaults.set("explicit-v1", forKey: Self.explicitOptInKey)
        }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(deniedApps.sorted(), forKey: Self.deniedAppsKey)
        defaults.set(userMultiplier, forKey: Self.multiplierKey)
    }

    /// The learned multiplier is all the engine mutates — persisting
    /// only it can't clobber a `mode`/`deniedApps` Settings write the
    /// reload observer hasn't landed yet.
    func saveLearned(to defaults: UserDefaults = .standard) {
        defaults.set(userMultiplier, forKey: Self.multiplierKey)
    }
}

/// The dwell engine — consumes the scorer's IntentEvent stream and emits
/// at most one `.fire` per acquire: a hold past the candidate's policy
/// delay commits. Releases, winner switches and feed-loss end a hold; a
/// hold that ended after real engagement without firing reports
/// `.aborted` so the learned multiplier can adapt. `.ambiguous` pauses
/// rather than aborts — the radial is asking, the clock just waits.
struct GazeDwell: Sendable, Equatable {
    enum Step: Equatable {
        case fire(IntentCandidate)
        case aborted
        case none
    }

    private var holdID: String?
    private var holdProgress: Double = 0
    private var fired = false

    /// How far into a hold counts as a real dwell — releases under the
    /// floor are glances at the winner, not aborted commits.
    static let abortFloor = 0.35

    mutating func reset() {
        holdID = nil; holdProgress = 0; fired = false
    }

    /// One scorer event in → the step out. `share` is the incumbent's
    /// softmax share at hold time (the referent's confidence).
    mutating func advance(_ event: IntentEvent, share: Double,
                          policy: DwellPolicy) -> Step {
        switch event {
        case .acquire(let c):
            let step = abortStep()
            holdID = c.id; holdProgress = 0; fired = false
            return step
        case .hold(let c, let progress):
            if holdID != c.id { holdID = c.id; holdProgress = 0; fired = false }
            holdProgress = progress
            guard !fired, policy.allows(c),
                  progress >= policy.delay(for: c, share: share)
            else { return .none }
            fired = true
            return .fire(c)
        case .release(let c):
            let step = holdID == c.id ? abortStep() : .none
            if holdID == c.id { holdID = nil; holdProgress = 0; fired = false }
            return step
        case .none:
            let step = abortStep()
            holdID = nil; holdProgress = 0; fired = false
            return step
        case .ambiguous:
            // A contested frame isn't a look-away — keep the hold; the
            // radial is asking, the dwell clock just pauses.
            return .none
        }
    }

    /// A hold that ended past the engagement floor without firing.
    private func abortStep() -> Step {
        guard holdID != nil, !fired, holdProgress >= Self.abortFloor else { return .none }
        return .aborted
    }
}

/// Where an implicit calibration label came from — the tracker weighs each
/// kind differently (EyeTracking core.ts `IMPLICIT_LABEL_KINDS`): how far
/// back the eyes were on the target, whether it may seed a first map, and
/// whether it is ground truth at all. A commit gaze itself chose only echoes
/// the map's guess, so it rides as low-weight bias evidence.
enum ImplicitLabelKind: String, Sendable {
    case cursorRest = "cursor_rest"
    case click
    case voice
    case caret
    case gazePick = "gaze_pick"
}

/// Invisible calibration's host half — confirmed commits, the user's own
/// clicks and the text caret post implicit calibration labels through the
/// tracker's control plane (`implicit_sample`, normalized to the tracker
/// display's bounds). The first transport error trips the breaker — a
/// tracker build without the action must not eat a POST per click;
/// `reset()` clears it on tracker restart.
actor ImplicitLabeler {
    /// Control-plane POST — production is `TrackerControl.post`.
    var post: @Sendable (String, Any?) async throws -> Void = { action, value in
        try await TrackerControl.post(action: action, value: value)
    }
    /// The tracker display's bounds for normalization — `/snapshot/display`.
    var displayBounds: @Sendable () async -> CGRect? = {
        await GazeClient().display()?.bounds
    }
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Seam injection for tests — actor-isolated vars can't be assigned
    /// from outside, so the seams arrive at construction.
    init(post: (@Sendable (String, Any?) async throws -> Void)? = nil,
         displayBounds: (@Sendable () async -> CGRect?)? = nil,
         now: (@Sendable () -> TimeInterval)? = nil) {
        if let post { self.post = post }
        if let displayBounds { self.displayBounds = displayBounds }
        if let now { self.now = now }
    }

    private(set) var tripped = false
    private var lastLabelled: (id: String, at: TimeInterval)?

    /// The same candidate re-committed inside this window doesn't
    /// re-label — labels mark changes of intent, not dwell duration.
    static let dedupeWindow: TimeInterval = 1.5
    /// A commit on anything bigger than this (a window, a page) says
    /// little about where the eyes were inside it — no label.
    static let maxLabelSide: CGFloat = 240

    /// Label one confirmed commit at `point`. Fails silently — a label is
    /// a courtesy to the calibration, never a reason to refuse a click.
    func commit(_ candidate: IntentCandidate, at point: CGPoint, kind: ImplicitLabelKind) async {
        guard !tripped,
              max(candidate.frame.width, candidate.frame.height) <= Self.maxLabelSide
        else { return }
        let t = now()
        if let last = lastLabelled,
           last.id == candidate.id, t - last.at < Self.dedupeWindow { return }
        if await send(point, kind: kind) { lastLabelled = (candidate.id, t) }
    }

    /// One label with no candidate behind it — the user's own click or
    /// the text caret.
    func label(at point: CGPoint, kind: ImplicitLabelKind) async {
        guard !tripped else { return }
        _ = await send(point, kind: kind)
    }

    /// Normalize against the tracker display and POST. A point off that
    /// display is no label (clamping it would invent one at the edge).
    private func send(_ point: CGPoint, kind: ImplicitLabelKind) async -> Bool {
        guard let bounds = await displayBounds(),
              bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return false }
        // Wire values are Double — a CGFloat in the Any dict won't
        // read back as Double for the tracker's JSON decoder.
        let value: [String: Any] = [
            "x_norm": Double((point.x - bounds.minX) / bounds.width),
            "y_norm": Double((point.y - bounds.minY) / bounds.height),
            "kind": kind.rawValue,
        ]
        do {
            try await post("implicit_sample", value)
            return true
        } catch {
            // Only a hard rejection trips the breaker — a 400/404 means
            // this tracker build doesn't know `implicit_sample`, and
            // every retry would be a wasted POST. A 409
            // (`tracking_inactive`: paused, calibrating, a renderer
            // reload) is a transient decline, and an unreachable
            // tracker heals — neither bricks labeling until restart.
            if case TrackerControlError.rejected(let code) = error,
               code != 409 {
                tripped = true
            }
            return false
        }
    }

    /// Tracker restart clears the breaker — a newer build may answer.
    func reset() { tripped = false; lastLabelled = nil }
}

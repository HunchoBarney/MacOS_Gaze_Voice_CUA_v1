import AppKit
import Foundation
import OSLog

/// Owns the eye-tracker child process — the tracker is a required component
/// (gaze-referent verbs depend on it), so the app spawns it on launch,
/// waits for its external API to serve, and stops it on quit.
///
/// Launch resolution, in order:
///   1. `Bundle.main.resourceURL/EyeTracker` — the bundled layout
///      `make bundle-tracker` stages under Contents/Resources; it
///      counts only with a scripts/ launcher inside, so a half-staged
///      bundle can't shadow a working path.
///   2. `JARVIS_EYE_TRACKER_DIR` — an explicit checkout or installed dir.
///   3. `../EyeTracking` relative to the app bundle's parent — the dev
///      layout (`build/Jev Voice.app` sits beside `EyeTracking/`).
///   4. `~/Library/Application Support/JevVoice/EyeTracking` — the
///      `make local` symlink into the live checkout.
///   5. `Bundle.main.resourceURL/EyeTracking` — the shipped layout once the
///      packaged Electron app is embedded.
///
/// Anything missing or unhealthy surfaces through `state` — gaze verbs
/// fail honestly from `GazeClient`, this host just owns the process.
///
/// Killing the tracker is never a bare `terminate()`: the node wrapper
/// dies alone and leaves vite/Electron grandchildren holding the API
/// port, so the next spawn dies on EADDRINUSE — that was the crash-loop.
/// `stopTrackerTree` is the one chain every kill goes through: a polite
/// `/control` quit, then SIGTERM, then a dir-scoped pkill last resort.
actor TrackerHost {
    static let shared = TrackerHost()
    /// The tracker's read-only API port (`--external-api-port` default).
    static let port = 47892

    enum State: Equatable, Sendable {
        case stopped, starting, running, failed(String)
    }
    private(set) var state: State = .stopped {
        didSet {
            if oldValue == .running, state != .running {
                // Whatever held the pause dies with the tracker — the flag
                // must not survive into a respawn's bookkeeping.
                pausedByLock = false
                lockParkingIdentity = UUID()
            }
            if oldValue != .running, state == .running, screenIsLocked {
                // A respawned/adopted tracker boots unpaused even while the
                // screen is still locked — re-park it from the persisted
                // lock state rather than waiting for an edge that won't
                // repeat.
                Task { await self.applyLockParking() }
            }
        }
    }
    private var process: Process?
    /// True while `.running` describes a tracker we adopted rather than
    /// spawned — there is no Process handle to terminate or wait on, so
    /// `armAdoptionWatch` stands in for the termination-handler exit
    /// watch and the stop chain's SIGTERM step is a skip (the /control
    /// quit and scoped sweep still apply to adoptees).
    private var adopted = false
    /// Spawn attempts since the app started — bounded so a tracker that
    /// crashes immediately doesn't restart-loop forever. A boot that
    /// stays healthy ~60s earns the budget back (`armAttemptReset`) —
    /// the bound is for crash loops, not for punishing a long-lived
    /// tracker's one bad night.
    private var attempts = 0
    static let maxAttempts = 2
    /// Which spawn attempt owns the tracker slot. Bumped on every
    /// ensureRunning claim and every deliberate stop, so a start that
    /// stayed suspended across a toggle (the 90s boot window is wide)
    /// can't resurrect itself under a newer claim — a start holding an
    /// old token retires quietly instead of claiming `.running` or
    /// killing the newer generation's fresh spawn.
    private var startGeneration = 0
    /// The dir this launch spawned from — kept for the orphan sweep.
    private var trackerDir: URL?
    /// Wedge watcher — polls /snapshot while a non-wasm tracker runs.
    private var wedgeWatch: Task<Void, Never>?
    /// /health poll that stands in for the exit handler while adopted.
    private var adoptionWatch: Task<Void, Never>?
    /// One-shot timer that refunds the spawn budget after a healthy
    /// minute — armed on every `.running` transition.
    private var attemptReset: Task<Void, Never>?
    /// Session-scoped: a wedged WebGPU boot escalates to wasm for the rest
    /// of this run only. WebGPU failures are intermittent (the provider
    /// works most boots and is ~6x faster), so a single wedge must NOT pin
    /// the machine to wasm permanently — the next launch retries the fast
    /// path. A manual `defaults write com.chriswozniczek.jevvoice
    /// trackerForceWasm 1` still forces wasm for machines where WebGPU
    /// never survives.
    private var forceWasm = UserDefaults.standard.bool(forKey: "trackerForceWasm")
    /// Once-per-boot latch — escalation flips the session to wasm; a second
    /// escalation this boot is never the right answer.
    private var wasmEscalated = false
    /// /health responder identity of the tracker that wedged — a
    /// responder's `started_at` boot stamp never changes, so it IS the
    /// process identity. Kept for the rest of the run: if the kill chain
    /// can't remove the wedged port-holder, any later adoption path must
    /// recognise the same responder and refuse — adopting it back would
    /// claim .running over the same dead pipeline with the wedge watch
    /// disarmed under forceWasm.
    private var wedgedResponder: ResponderIdentity?

    /// Screen-lock parking — the camera and inference don't need to burn
    /// power while nobody can see the screen. DistributedNotificationCenter
    /// posts the session edges; each edge (and each `.running` transition,
    /// via the state didSet) funnels through `applyLockParking`, which
    /// drives the tracker-side `paused` flag — that flag is also the wedge
    /// watch's exemption, so a parked tracker's silence never reads as a
    /// stall. Armed once for the process lifetime; every handler guards on
    /// `.running`, so observers left registered while stopped are inert.
    private var lockObservers: [NSObjectProtocol] = []
    /// The last delivered lock state — kept so a tracker that respawned
    /// mid-lock gets re-parked on its `.running` transition instead of
    /// booting straight into camera+inference under a locked screen.
    private var screenIsLocked = false
    /// True only while the current pause exists because WE asked for it on
    /// lock. A pause the user set by hand must survive the unlock — the
    /// lock path reads the snapshot first and never claims a pause that
    /// was already there.
    private var pausedByLock = false
    private var lockParkingIdentity = UUID()
    private var lockParkingActive = false
    private var lockParkingPending = false

    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "tracker")

    /// A gaze sample older than this counts as dead air — the pipeline
    /// emits at least ~10fps while tracking, so nothing healthy is quiet
    /// for 6s.
    private static let gazeStaleWindow: TimeInterval = 6
    /// First-frame allowance after `.running`: the API serves as soon as
    /// Electron's main process runs, long before the renderer compiles
    /// WebGPU shaders and lands its first frame. A tracker that never
    /// lands one within the grace IS silently dead — the window is what
    /// tells "still warming" from "dead".
    private static let gazeGraceWindow: TimeInterval = 45
    /// Consecutive dead-API probes before a spawned child counts as
    /// wedged — a dead API on a live process is as stuck as a dead
    /// session. Adoptees get the same check from `armAdoptionWatch`.
    private static let healthMissLimit = 3
    /// Non-healthy verdicts in a row before escalating — one dropped
    /// frame or a mid-reload flap must not flip providers.
    private static let wedgeSightingsToEscalate = 2
    /// /snapshot poll cadence for the wedge watch — 1.5s so a bad boot
    /// surfaces for the second escalation probe in ~3s instead of ~6s.
    /// A static so tests pin the contract rather than the literal.
    static let wedgePollInterval: Duration = .milliseconds(1500)

    // MARK: - Wedge detection

    /// What one /snapshot read means to the watch loop. `healthy` covers
    /// genuinely-fine snapshots AND errors a respawn can't fix (camera
    /// denied, model fetch failed — those log once and keep watching);
    /// `wedged` is a dead-inference signature in the served status;
    /// `stalled` is the quieter wedge — tracking is on but the gaze
    /// pipeline went silent, which is a wedge all the same.
    enum WedgeSignal: Equatable, Sendable {
        case healthy, wedged(String), stalled
    }

    /// The wedge signature in the tracker's served status — pure, so
    /// tests drive it with no socket. Escalate ONLY on a real inference
    /// wedge:
    ///   - `status.level == "error"` whose message carries a dead-
    ///     session/reload token: `cannot run inference`,
    ///     `invalid session`, `failed to reload`, `unrecoverable`,
    ///     `OrtRun` (case-insensitive).
    ///   - a stale gaze (`gazeIsFresh == false`) while the tracker
    ///     reports tracking — `paused` absent counts as not paused.
    /// Everything else — camera/permission/init errors like
    /// NotAllowedError, "permission denied", model fetch failures — is a
    /// healthy-other problem a respawn can't fix, so it never escalates.
    /// Wedge tokens win over the benign set on overlap: "Failed to
    /// reload models with wasm" names a model but IS the reload wedge
    /// the provider can't self-heal.
    nonisolated static func wedgeSignal(for snapshot: [String: Any],
                                        gazeIsFresh: Bool) -> WedgeSignal {
        if let status = snapshot["status"] as? [String: Any],
           (status["level"] as? String)?.lowercased() == "error" {
            let message = (status["message"] as? String) ?? ""
            let lowered = message.lowercased()
            let wedgeTokens = ["cannot run inference", "invalid session",
                               "failed to reload", "unrecoverable", "ortrun"]
            if wedgeTokens.contains(where: { lowered.contains($0) }) {
                return .wedged(message)
            }
            return .healthy
        }
        // A paused tracker produces no gaze on purpose — silence there
        // isn't a wedge.
        if !gazeIsFresh, (snapshot["paused"] as? Bool) != true {
            return .stalled
        }
        return .healthy
    }

    /// The served status' message when it reports `level:"error"` — the
    /// watch loop logs these once per distinct message so a denied
    /// camera doesn't spam every poll.
    nonisolated static func statusError(in snapshot: [String: Any]) -> String? {
        guard let status = snapshot["status"] as? [String: Any],
              (status["level"] as? String)?.lowercased() == "error",
              let message = status["message"] as? String,
              !message.isEmpty else { return nil }
        return message
    }

    /// "Is the gaze pipeline producing?" — yes while `gaze.updated_at`
    /// is ≤ `gazeStaleWindow` old. Before the first frame there is no
    /// stamp at all: a missing one reads as fresh only inside the
    /// post-start `gazeGraceWindow`, so cold-boot shader compiles never
    /// escalate while a never-producing pipeline still does.
    nonisolated static func gazeIsFresh(in snapshot: [String: Any],
                                        runningSince: Date,
                                        now: Date = Date()) -> Bool {
        if let gaze = snapshot["gaze"] as? [String: Any],
           let text = gaze["updated_at"] as? String,
           let stamp = Self.iso.date(from: text) ?? Self.isoPlain.date(from: text) {
            return now.timeIntervalSince(stamp) <= Self.gazeStaleWindow
        }
        return now.timeIntervalSince(runningSince) <= Self.gazeGraceWindow
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    // MARK: - Lifecycle

    /// Spawn the tracker if its API isn't already serving — a tracker the
    /// user started by hand is adopted, never duplicated.
    func ensureRunning() {
        switch state {
        case .stopped, .failed: break
        default: return
        }
        guard attempts < Self.maxAttempts else { return }
        // Check-and-set before the Task: two callers in the same beat
        // would otherwise both pass the .stopped check and double-spawn.
        // The generation token is what a queued start compares against —
        // a stop() or a newer claim superseding it must leave it inert.
        armScreenLockWatch()
        state = .starting
        startGeneration += 1
        let generation = startGeneration
        Task { await start(generation: generation) }
    }

    /// Deliberate stop — spends the spawn budget so nothing respawns
    /// behind the user's back, then kills the whole tree. Async so the
    /// app-quit path (`applicationShouldTerminate`) waits for the kill
    /// to land before answering.
    func stop() async {
        attempts = Self.maxAttempts
        // Supersede any start still suspended in its boot window — it
        // must retire quietly, not claim .running behind the deliberate
        // .stopped.
        startGeneration += 1
        wedgeWatch?.cancel()
        adoptionWatch?.cancel()
        attemptReset?.cancel()
        let proc = process
        // Only run the kill chain when this host actually owns a tracker —
        // a live child handle, an adoption, or a dir we already spawned
        // from. With none of those, the /control quit and the dir-scoped
        // sweep would land on a FOREIGN tracker the user started by hand:
        // quitting the app must not murder a process it never made.
        let owned = proc != nil || adopted || trackerDir != nil
        process = nil
        adopted = false
        state = .stopped
        if owned { await stopTrackerTree(proc) }
    }

    /// A user-initiated enable — the menu item, Settings toggle and the
    /// enable verb all funnel here through the Config sink. A deliberate
    /// start clears the spawn-attempt bound an earlier `stop()` or crash
    /// budget left behind. Exit-handler respawns keep going through
    /// `ensureRunning` alone, so the bound still holds for crashes.
    func userRequestedStart() {
        attempts = 0
        ensureRunning()
    }

    private func start(generation: Int) async {
        // Stale on arrival — a stop() or a newer ensureRunning superseded
        // this claim while the Task queued. Exit before touching
        // anything: watches a newer start armed are not ours to cancel.
        guard generation == startGeneration, state == .starting else { return }
        wedgeWatch?.cancel()
        adoptionWatch?.cancel()
        attemptReset?.cancel()
        guard await healthy() == false else {
            // A stop() or a newer start that landed between the claim and
            // this probe must not be undone by an adoption.
            guard generation == startGeneration, state == .starting else { return }
            if Self.releaseProfile != nil {
                state = .failed("Another tracker is already using the release tracker port.")
                return
            }
            // Post-escalation adoption must verify the responder isn't the
            // same wedged tracker the kill chain failed to remove —
            // /health identity is process-stable, so an equal identity
            // (same started_at, or both sides answering without one — a
            // responder we can't tell apart can't be proven different)
            // means "the wedge survived". Adopting it would claim
            // .running over a dead pipeline with the wedge watch disarmed
            // under forceWasm — fail honestly instead.
            if let wedged = wedgedResponder,
               await responderIdentity() == wedged {
                Self.log.error("port still held by the wedged tracker — refusing to re-adopt it")
                state = .failed("The eye tracker wedged and would not stop — restart it by hand.")
                return
            }
            Self.log.notice("tracker already serving on port \(Self.port) — adopted")
            adopted = true
            state = .running
            armAttemptReset()
            armWedgeWatch()
            armAdoptionWatch()
            return
        }
        // The probe suspended — re-check the claim before doing spawn
        // work. The off→on toggle inside a 90s boot window is exactly
        // how a stale start used to claim .running under a newer one.
        guard generation == startGeneration, state == .starting else { return }
        // JARVIS_DISABLE_TRACKER_SPAWN is the tests' hatch — the respawn
        // claim and the stale-generation path are exercised without ever
        // forking a real child. Placed before the attempts guard so a
        // stale-generation regression reads as .failed, never a quiet
        // pass.
        guard ProcessInfo.processInfo.environment["JARVIS_DISABLE_TRACKER_SPAWN"] == nil else {
            state = .failed("tracker spawn disabled (JARVIS_DISABLE_TRACKER_SPAWN)")
            return
        }
        guard let dir = Self.trackerDirectory() else {
            Self.log.error("no EyeTracking checkout found (set JARVIS_EYE_TRACKER_DIR) — gaze verbs will refuse")
            state = .failed("The eye tracker isn't installed where I can find it.")
            return
        }
        guard attempts < Self.maxAttempts else {
            // The bound was spent between ensureRunning's check and now
            // (a stop() landed mid-flight) — don't leave state parked on
            // .starting forever.
            state = .stopped
            return
        }
        // ELECTRON_RUN_AS_NODE poisons the tracker when the app itself was
        // launched from an Electron process tree (it turns the Electron
        // binary into plain node — `require("electron")` returns a path,
        // main.cjs crashes on `app` being undefined).
        var env = ProcessInfo.processInfo.environment
        if Self.releaseProfile != nil {
            guard let extra = Self.portableExtraArguments(env["JARVIS_EYE_TRACKER_ARGS"], forceWasm: forceWasm) else {
                state = .failed("The portable eye tracker does not accept experiment arguments.")
                return
            }
            env["JARVIS_EYE_TRACKER_ARGS"] = extra.isEmpty ? nil : extra.joined(separator: " ")
            for key in ["NODE_OPTIONS", "NODE_PATH", "ELECTRON_OVERRIDE_DIST_PATH", "VITE_DEV_SERVER_URL"] {
                env.removeValue(forKey: key)
            }
        }
        // NODE_ENV must NOT leak through: under =production vite dev
        // skips the react-refresh preamble and the renderer crashes on
        // $RefreshSig$. start-prod.cjs sets =production itself.
        env.removeValue(forKey: "NODE_ENV")
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        env.removeValue(forKey: "ELECTRON_NO_ATTACH_CONSOLE")
        // node on a GUI app's PATH is bare — resolve it explicitly rather
        // than trusting /usr/bin/env to find it.
        guard let node = Self.nodeBinary(environment: env, trackerDir: dir) else {
            Self.log.error("node not found (homebrew dirs, app PATH and login shell all missed)")
            state = .failed("The eye tracker needs node.js, which I couldn't find on this Mac.")
            return
        }
        // Prefer the prod renderer when the checkout carries both a dist
        // build and its launcher: start-prod.cjs points Electron straight
        // at dist/ with NODE_ENV=production, skipping vite entirely. The
        // old "prod wedges on file://" claim is being re-verified — prod
        // loses nothing today. Checkouts without a build keep dev.cjs,
        // the proven vite+electron path.
        let useProdRenderer = ["dist/index.html", "scripts/start-prod.cjs"].allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        guard Self.releaseProfile == nil || useProdRenderer else {
            state = .failed("The bundled release renderer is missing.")
            return
        }
        Self.log.notice("tracker node=\(node.path, privacy: .public) renderer=\(useProdRenderer ? "prod" : "dev", privacy: .public)")
        let proc = Process()
        proc.executableURL = node
        proc.environment = env
        proc.arguments = Self.trackerArguments(trackerDir: dir,
                                               useProdRenderer: useProdRenderer,
                                               forceWasm: forceWasm,
                                               defaults: .standard,
                                               environment: env)
        proc.currentDirectoryURL = dir
        // The tracker's stderr is the only place a boot failure explains
        // itself (vite bind, Electron exit, EADDRINUSE) — nil stdio made
        // the last crash silent. Truncate per spawn so the log is always
        // the most recent boot, not an unbounded append — createFile does
        // NOT truncate an existing file, so do it on the handle itself.
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        let logURL = support.appendingPathComponent("tracker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.truncateFile(atOffset: 0)
            proc.standardOutput = handle
            proc.standardError = handle
        }
        // The exit watch is a terminationHandler, never a Task that
        // waitUntilExit()s — that call is a synchronous block and a Task
        // spawned inside this actor inherits its serial executor, so the
        // old monitorExit froze the actor for the child's whole life:
        // stop(), state reads (the Eyes menu), the watches and the
        // respawn itself all dead, which is why the tracker survived app
        // quit. The handler fires on a private queue and hops onto the
        // actor with the dead pid; handleExit's identity check is what
        // keeps an intentional kill or a replaced spawn off the respawn
        // path, so arming it BEFORE run() is safe even for an instant
        // exit.
        proc.terminationHandler = { [weak self] finished in
            Task { await self?.handleExit(pid: finished.processIdentifier) }
        }
        attempts += 1
        do {
            try proc.run()
            Self.log.notice("tracker spawned (dir=\(dir.path, privacy: .public), attempt \(self.attempts))")
        } catch {
            Self.log.error("tracker spawn failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("The eye tracker failed to start.")
            return
        }
        process = proc
        trackerDir = dir
        adopted = false

        // Give the API up to ~90s to serve before declaring the boot
        // dead — a cold vite build plus Electron start is most of that.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if await healthy() {
                // A stop() or a newer start that landed mid-boot must
                // not be overwritten — the stale claim retires its own
                // spawn and leaves the current generation standing.
                guard generation == startGeneration, state == .starting else {
                    await retireSpawn(proc)
                    return
                }
                state = .running
                Self.log.notice("tracker API serving on port \(Self.port)")
                armAttemptReset()
                armWedgeWatch()
                return
            }
            if !proc.isRunning || state != .starting
                || generation != startGeneration { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // Dead, stopped mid-boot, superseded or timed out — retire the
        // spawn; the kill is skipped only when a newer generation
        // adopted this very process (then it IS the live tracker).
        // terminate() alone would orphan vite/Electron on the port, and
        // stop() may already have run the same chain — it's idempotent.
        await retireSpawn(proc)
        guard generation == startGeneration, state == .starting else { return }
        state = .failed("The eye tracker started but never answered on port \(Self.port).")
        Self.log.error("tracker never served its API within 90s — killed")
    }

    /// Give up a spawned child that never claimed `.running` — dead,
    /// timed out, stopped mid-boot or superseded by a newer generation.
    /// The whole-tree kill runs UNLESS a newer generation already
    /// adopted this very process — then it IS the live tracker and
    /// killing it murders the service. `process` is released on
    /// identity alone, so the current generation's child is never
    /// cleared from under it.
    func retireSpawn(_ proc: Process) async {
        if !(adopted && state == .running) {
            await stopTrackerTree(proc)
        }
        if process === proc { process = nil }
    }

    /// A child exit, delivered by the termination handler with the dead
    /// pid. Only an exit that still owns `process` counts: stale
    /// handlers from replaced spawns, and deliberate kills where
    /// stop()/escalateToWasm already cleared the handle, fail the
    /// identity check and die ignored — the check, not a separate flag,
    /// is what keeps an intentional kill off the respawn path.
    ///
    /// Only a tracker that reached `.running` respawns: a mid-boot
    /// death is the boot loop's own cleanup (it sees `!isRunning` and
    /// writes the honest .failed), and respawning here would race it.
    /// One respawn while the app still expects the tracker; a second
    /// death stays dead (attempts bound it).
    func handleExit(pid: Int32) {
        guard process?.processIdentifier == pid else { return }
        process = nil
        guard state == .running else { return }
        guard attempts < Self.maxAttempts else {
            state = .failed("The eye tracker exited and won't be restarted.")
            return
        }
        Self.log.notice("tracker exited unexpectedly — respawning")
        state = .stopped
        ensureRunning()
    }

    /// A tracker that stays `.running` past ~60s earned its spawn budget
    /// back — `attempts` bounds crash loops, not lifetime crashes.
    private func armAttemptReset() {
        attemptReset?.cancel()
        attemptReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            await self.resetAttemptsIfRunning()
        }
    }
    private func resetAttemptsIfRunning() {
        if state == .running { attempts = 0 }
    }

    // MARK: - Wedge + adoption watches

    /// One /snapshot probe, classified for the watch loop.
    private enum SnapshotProbe {
        /// The API itself didn't answer — a health miss, not a verdict.
        case unreachable
        /// `wedgeSignal`'s verdict plus the served status error message,
        /// if any — logged once so non-wedge errors don't spam.
        case verdict(WedgeSignal, error: String?)
    }

    /// Fetch the full /snapshot (one GET, same data as the
    /// /snapshot/status + /snapshot/gaze slices) and fold in gaze
    /// freshness + the post-start grace before `wedgeSignal` judges.
    /// Any fetch/decode/non-200 is a health miss.
    private func probeSnapshot(runningSince: Date) async -> SnapshotProbe {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/snapshot") else {
            return .verdict(.healthy, error: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreachable }
        return .verdict(
            Self.wedgeSignal(for: snapshot,
                             gazeIsFresh: Self.gazeIsFresh(in: snapshot,
                                                         runningSince: runningSince)),
            error: Self.statusError(in: snapshot))
    }

    /// Poll /snapshot while a non-wasm tracker runs — same watch for
    /// spawned children and adoptees. Escalation needs two consecutive
    /// non-healthy verdicts so a dropped frame or a mid-reload flap can't
    /// flip providers; the tracker already retries wedges in place first,
    /// so the watch only fires on a wedge it can't self-heal.
    private func armWedgeWatch() {
        guard !forceWasm else { return }
        wedgeWatch?.cancel()
        wedgeWatch = Task { [weak self] in
            var sightings = 0
            var healthMisses = 0
            var loggedError: String?
            // The grace runs from when the watch armed — adoption lands
            // right after /health answered, so a still-warming adoptee
            // gets the same first-frame allowance a spawned boot does.
            let runningSince = Date()
            while let self, !Task.isCancelled {
                // 1.5s cadence: a real wedge still needs two consecutive
                // sightings (3s to escalate), but a bad boot surfaces for
                // the second probe twice as fast as the old 3s poll.
                try? await Task.sleep(for: Self.wedgePollInterval)
                guard !Task.isCancelled else { return }
                let (running, forced, isAdopted) = await (self.state, self.forceWasm, self.adopted)
                guard running == .running, !forced else { return }
                switch await self.probeSnapshot(runningSince: runningSince) {
                case .unreachable:
                    healthMisses += 1
                    // An adoptee's dead API is the adoption poll's job —
                    // don't double-drive the respawn from here. For a
                    // spawned child, a dead API on a live process is as
                    // wedged as a dead session.
                    if !isAdopted, healthMisses >= Self.healthMissLimit {
                        Self.log.error("tracker API stopped answering — treating as wedged")
                        await self.escalateToWasm()
                        return
                    }
                case .verdict(let signal, let statusError):
                    healthMisses = 0
                    if let statusError, statusError != loggedError {
                        // level:"error" without a wedge token — camera
                        // denied, model fetch failed, init blew up. A
                        // respawn can't fix any of them; say so once.
                        Self.log.error("tracker reports a non-wedge error: \(statusError, privacy: .public)")
                        loggedError = statusError
                    }
                    switch signal {
                    case .healthy:
                        sightings = 0
                    case .wedged(let detail):
                        sightings += 1
                        guard sightings >= Self.wedgeSightingsToEscalate else { continue }
                        Self.log.notice("tracker wedge signature (\(detail, privacy: .public)) — escalating")
                        await self.escalateToWasm()
                        return
                    case .stalled:
                        sightings += 1
                        guard sightings >= Self.wedgeSightingsToEscalate else { continue }
                        Self.log.notice("tracker gaze pipeline silent while tracking — escalating")
                        await self.escalateToWasm()
                        return
                    }
                }
            }
        }
    }

    /// A spawned child's death surfaces through the termination handler;
    /// an adopted tracker has no handle to wait on, so poll /health
    /// instead — three
    /// consecutive misses means the tracker we adopted is gone, and the
    /// respawn should be a real child this time.
    private func armAdoptionWatch() {
        adoptionWatch?.cancel()
        guard adopted else { return }
        adoptionWatch = Task { [weak self] in
            var misses = 0
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                let (running, isAdopted) = await (self.state, self.adopted)
                guard running == .running, isAdopted else { return }
                if await self.healthy() {
                    misses = 0
                    continue
                }
                misses += 1
                if misses >= Self.healthMissLimit {
                    Self.log.notice("adopted tracker stopped answering /health — respawning a hosted child")
                    await self.adopteeDied()
                    return
                }
            }
        }
    }

    /// The adopted tracker stopped answering — clear the adoption and
    /// respawn a real child through the normal budget path.
    private func adopteeDied() {
        wedgeWatch?.cancel()
        adoptionWatch?.cancel()
        attemptReset?.cancel()
        adopted = false
        // .starting marks the transition synchronously — the sweep runs
        // before ensureRunning so nobody can spawn into a port the
        // corpse's orphans may still hold.
        state = .starting
        Task {
            await self.stopTrackerTree(nil)
            state = .stopped
            ensureRunning()
        }
    }

    // MARK: - Screen-lock parking

    /// Session lock/unlock edges arrive on the distributed center. Armed on
    /// the first spawn claim and left registered for the process lifetime —
    /// a tracker that isn't running makes every edge a no-op, and removing
    /// observers mid-flight would just risk missing an edge that lands
    /// between disarm and re-arm.
    private func armScreenLockWatch() {
        guard lockObservers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true),
                               ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(
                center.addObserver(forName: NSNotification.Name(name),
                                   object: nil,
                                   queue: nil) { [weak self] _ in
                    Task { await self?.handleScreenLockChange(locked) }
                })
        }
    }

    /// One lock/unlock edge — record it, then apply. Keeping the state
    /// (rather than acting only on the edge) is what lets the `.running`
    /// transition re-park a tracker that respawned while locked.
    private func handleScreenLockChange(_ locked: Bool) async {
        screenIsLocked = locked
        await applyLockParking()
    }

    /// Park or unpark the tracker for the persisted lock state. Parking is
    /// the tracker-side `paused` flag through `/control set_paused` — the
    /// same flag a manual pause sets, so the snapshot reports it, the wedge
    /// watch excuses the silence, and the renderer's paused overlay applies
    /// unchanged. A pause that was already there when the screen locked is
    /// the user's own — unlocking never resurrects it.
    ///
    /// The body is a converge loop, not a single pass: every suspended
    /// status read / control POST is a window where the opposite edge can
    /// land (its own applyLockParking run sees pausedByLock still false and
    /// returns without a POST). Re-reading `screenIsLocked` after each
    /// suspend is what keeps a pause POST that was in flight during an
    /// unlock from parking an unlocked screen forever — the loop hands the
    /// pause right back, and a re-lock mid-resume parks again.
    private func applyLockParking() async {
        guard !lockParkingActive else {
            lockParkingPending = true
            return
        }
        lockParkingActive = true
        defer {
            lockParkingActive = false
            if lockParkingPending {
                lockParkingPending = false
                Task { await self.applyLockParking() }
            }
        }
        while state == .running {
            lockParkingPending = false
            let identity = lockParkingIdentity
            if screenIsLocked {
                guard !pausedByLock else { return }
                do {
                    // Read before claiming the pause — a user pause present
                    // at lock time stays theirs to undo. Re-check the lock
                    // edge after the suspended read: an unlock that landed
                    // meanwhile already returned early and must not get a
                    // stale park posted under it.
                    let status = try await TrackerControl().status()
                    guard state == .running, lockParkingIdentity == identity else { continue }
                    if status.paused { return }
                    guard screenIsLocked else { continue }
                    try await TrackerControl().post(action: "set_paused", value: true)
                    guard state == .running, lockParkingIdentity == identity else { continue }
                    // Claim the pause the moment it lands — even if the
                    // screen already unlocked: the loop's else-branch then
                    // owns the undo, so the pause can never linger
                    // unclaimed.
                    pausedByLock = true
                } catch {
                    // A dead or refusing tracker can't be parked — log and
                    // leave the flag clear so the unlock edge doesn't
                    // unpause a pause we never set.
                    Self.log.notice("screen-lock pause request didn't land: \(error.localizedDescription, privacy: .public)")
                    return
                }
            } else {
                guard pausedByLock else { return }
                pausedByLock = false
                do {
                    try await TrackerControl().post(action: "set_paused", value: false)
                } catch {
                    // The tracker keeps its pause; the flag is already
                    // cleared so a later unlock edge won't replay a stale
                    // intent. Honest degradation: the user unpauses by hand
                    // (⌘⇧P/tray).
                    Self.log.notice("screen-unlock resume request didn't land: \(error.localizedDescription, privacy: .public)")
                }
                // A re-lock that landed during the resume POST loops back
                // into the park branch; otherwise we're done.
            }
        }
    }

    /// Flip to the wasm provider and relaunch — WebGPU wedged this boot,
    /// so this session falls back to the reliable path. Deliberately not
    /// persisted: the failure is intermittent and wasm runs ~6x slower, so
    /// the next launch gets another shot at the fast path. Bounded to once
    /// per boot — a pipeline that wedges again is a .failed verdict, not
    /// a second provider flip.
    private func escalateToWasm() {
        guard !wasmEscalated else { return }
        wasmEscalated = true
        forceWasm = true
        Self.log.notice("tracker wedged — respawning with --web-accelerator wasm this session")
        wedgeWatch?.cancel()
        adoptionWatch?.cancel()
        attemptReset?.cancel()
        // Nil first so the termination handler doesn't race this
        // respawn — a deliberate kill reads as unexpected exit
        // otherwise. An adoptee
        // has no handle to nil — its kill runs through the /control quit
        // and the scoped sweep instead (an adopted tracker that isn't our
        // hosted build can't be told apart, and quit is the correct
        // request either way).
        let proc = process
        process = nil
        adopted = false
        // The wasm relaunch is a different strategy, not the same crash
        // looping — it gets the full spawn budget.
        attempts = 0
        state = .starting
        Task {
            // The responder holding the port right now IS the wedged
            // tracker — take its identity before the kill so a survivor
            // can't be re-adopted as a fresh tracker afterwards.
            wedgedResponder = await self.responderIdentity()
            await self.stopTrackerTree(proc)
            await self.restartWhenPortFrees()
        }
    }

    /// Orphaned children can hold the API port for a beat after the parent
    /// dies — spawning into a bound port is an instant EADDRINUSE death.
    /// If the port-holder after the kill chain + grace is still the wedged
    /// responder itself (a foreign tracker rooted outside this host's dir
    /// escapes the scoped sweep by design), restarting would just re-adopt
    /// the same dead pipeline — fail honestly instead.
    private func restartWhenPortFrees() async {
        for _ in 0..<24 {
            if await !healthy() { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let wedged = wedgedResponder,
           await responderIdentity() == wedged {
            // A stop() that landed mid-wait still owns the slot — only the
            // escalation's own .starting claim may write the verdict.
            guard state == .starting else { return }
            Self.log.error("wedged tracker survived the escalation kill chain — declaring failed instead of re-adopting it")
            state = .failed("The eye tracker wedged and would not stop — restart it by hand.")
            return
        }
        state = .stopped
        ensureRunning()
    }

    // MARK: - Killing the whole tree

    /// The single kill chain — `stop()`, the boot-timeout kill, the wasm
    /// escalation and the adoptee-death path all funnel here so no caller
    /// can orphan grandchildren:
    ///   1. `POST /control {"action":"quit"}` — the tracker's own graceful
    ///      exit: `app.quit()` runs before-quit teardown, Electron's exit
    ///      ends the dev wrapper, which reaps vite. A tracker too old to
    ///      know the action answers 400, harmless.
    ///   2. `proc.terminate()` — SIGTERM the wrapper we spawned; its
    ///      SIGTERM handler kills vite + Electron itself. Skipped for
    ///      adoptees (`process == nil` — never terminate a nil child).
    ///   3. `scopedOrphanSweep()` — the pkill last resort.
    /// An adopted tracker can't be told apart from a foreign standalone
    /// run — quit is still the correct request for either, and the sweep
    /// only reaches processes rooted in OUR resolved tracker dir.
    private func stopTrackerTree(_ proc: Process?) async {
        await requestTrackerQuit()
        // Give the graceful quit ~3s to stop answering before SIGTERM.
        for _ in 0..<6 {
            if await !healthy() { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let proc, proc.isRunning {
            proc.terminate()
            for _ in 0..<6 {
                if !proc.isRunning { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        scopedOrphanSweep()
    }

    /// POST {"action":"quit"} on the tracker's control port — acknowledged
    /// 202 then honoured on the next tick, so the answer lands before the
    /// API goes down. Errors (dead socket, 400 on an older build) are
    /// fine — the SIGTERM step is next either way.
    private func requestTrackerQuit() async {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/control") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"action":"quit"}"#.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Last resort: pkill -f everything whose argv anchors under the
    /// tracker's REALPATH-resolved `node_modules`. Resolution matters —
    /// the installed layout is a symlink (app-support → checkout) but
    /// node realpath's the script path, so vite/Electron argv carry the
    /// resolved dir, never the link; pkill on the unresolved path would
    /// match nothing.
    ///
    /// Blast radius: `<dir>/node_modules` is the narrowest pattern that
    /// still covers every grandchild — vite, the Electron binary and its
    /// helpers all launch from paths under it — while matching nothing
    /// else on the machine. The `node scripts/dev.cjs` wrapper runs on a
    /// relative argv and escapes the sweep by design: proc.terminate()
    /// covers our own child, and an adopted wrapper exits on its own
    /// once Electron dies.
    private func scopedOrphanSweep() {
        guard let dir = (trackerDir ?? Self.trackerDirectory())?.resolvingSymlinksInPath()
        else { return }
        let pattern = NSRegularExpression.escapedPattern(
            for: dir.appendingPathComponent("node_modules").path)
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        sweep.arguments = ["-f", pattern]
        // Best-effort, never awaited — a waitUntilExit() here would
        // park the actor for the sweep's whole run. The status lands in
        // the log when pkill exits, on Foundation's private queue.
        sweep.terminationHandler = { finished in
            Self.log.notice("tracker orphan sweep: pkill -f \(pattern, privacy: .public) (status \(finished.terminationStatus))")
        }
        try? sweep.run()
    }

    // MARK: - Spawn

    /// Where `node` lives — a GUI app's PATH is minimal (`/usr/bin:/bin`
    /// and little more), so resolve it explicitly: the bundled payload's
    /// own `bin/node` first (staged by `bundle-tracker.sh` so a packaged
    /// app has zero external dependencies), then the two Homebrew
    /// canonicals, then the PATH the app was launched with (what
    /// `command -v` would see), then a login shell so nvm/volta installs
    /// that only exist after shell init still resolve. nil fails
    /// honestly at the caller — better than /usr/bin/env dying opaquely
    /// inside the tracker boot.
    nonisolated static func nodeBinary(environment: [String: String], trackerDir: URL? = nil,
                                       bundledOnly: Bool = releaseProfile != nil) -> URL? {
        let fm = FileManager.default
        if let trackerDir {
            let staged = trackerDir.appendingPathComponent("bin/node")
            if fm.isExecutableFile(atPath: staged.path), !bundledOnly || staged.resolvingSymlinksInPath().path == staged.path {
                return staged
            }
        }
        guard !bundledOnly else { return nil }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let path = String(dir) + "/node"
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        // Login shell — `zsh -l` sources the profile where nvm/volta
        // publish their shims. Bounded at 5s so a stuck profile can't
        // park tracker boot.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v node"]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while probe.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if probe.isRunning {
            probe.terminate()
            return nil
        }
        let found = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !found.isEmpty, fm.isExecutableFile(atPath: found) else { return nil }
        return URL(fileURLWithPath: found)
    }

    /// The tracker argv (minus argv[0] — `node` is the executableURL).
    /// Split out nonisolated so tests drive every flag without spawning —
    /// the only filesystem touches are the dev.cjs fallback check (keyed
    /// off the handed-in `trackerDir`) and the bundled-layout check that
    /// redirects calibration out of a sealed Resources dir.
    ///
    /// Geometry comes from UserDefaults so Settings edits don't need a
    /// rebuild — `trackerDisplaySizeInch` (Double), `trackerCameraFovDeg`
    /// (Int), `trackerProjectionMode` (String), `trackerWasmThreads`
    /// (Int); `JARVIS_EYE_TRACKER_ARGS` is the raw escape hatch — the
    /// bundled-calibration redirect goes after it, since the tracker
    /// honors the first occurrence of a flag.
    nonisolated static func trackerArguments(trackerDir: URL,
                                             useProdRenderer: Bool,
                                             forceWasm: Bool,
                                             defaults: UserDefaults,
                                             environment: [String: String],
                                             hostPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> [String] {
        // --no-tray is the hosted-mode marker: the tracker's Electron
        // tray is for standalone dev runs — under the host, this app's
        // status item is the one menu-bar icon and owns the tracker
        // controls.
        var script = useProdRenderer ? "scripts/start-prod.cjs" : "scripts/dev.cjs"
        if !useProdRenderer,
           !FileManager.default.fileExists(
               atPath: trackerDir.appendingPathComponent("scripts/dev.cjs").path) {
            script = "scripts/start.cjs"
        }
        var arguments = [script, "--external-api", "--no-tray",
                         // The tracker's death watchdog: it polls this pid
                         // and self-quits the moment we're gone — a crashed
                         // or force-quit host can't orphan it, because one
                         // app means the tracker never outlives the host.
                         "--host-pid", "\(hostPid)"]
        // Display size: explicit default wins; otherwise the main
        // display's physical diagonal (CGDisplayScreenSize is real
        // millimetres — pixel metrics would misreport Retina panels);
        // omit the flag when CoreGraphics can't say.
        let displaySize = defaults.double(forKey: "trackerDisplaySizeInch")
        if displaySize > 0 {
            arguments += ["--display-size-inch", "\(displaySize)"]
        } else if let detected = Self.mainDisplayDiagonalInch() {
            arguments += ["--display-size-inch", String(format: "%.2f", detected)]
        }
        let fov = defaults.integer(forKey: "trackerCameraFovDeg")
        if fov > 0 {
            arguments += ["--camera-fov", "\(fov)"]
        }
        // binocular-screen is the tuned production projection — always
        // pass it unless the defaults key overrides for an experiment.
        let projection = defaults.string(forKey: "trackerProjectionMode") ?? ""
        arguments += ["--gaze-projection-mode", projection.isEmpty ? "binocular-screen" : projection]
        let wasmThreads = defaults.integer(forKey: "trackerWasmThreads")
        if wasmThreads > 0 {
            arguments += ["--wasm-threads", "\(wasmThreads)"]
        }
        // Session fallback after a wedged WebGPU boot (or a manual
        // trackerForceWasm default) — the fps cap keeps the pipeline from
        // burning cycles queuing frames wasm (~300ms/frame) can't reach.
        if forceWasm { arguments += ["--web-accelerator", "wasm", "--gaze-max-fps", "10"] }
        // Extra tracker flags (calibration overrides, experiment toggles)
        // come from the environment so Settings doesn't need a relaunch
        // to change them: JARVIS_EYE_TRACKER_ARGS="--display-size-inch 31.5".
        if let extra = environment["JARVIS_EYE_TRACKER_ARGS"] {
            arguments += extra.split(separator: " ").map(String.init)
        }
        // A tracker staged inside the app bundle cannot write its default
        // calibration path — Contents/Resources is sealed once the bundle
        // is signed — so bundled runs redirect .gaze_calibration.json (and
        // settings.json, which resolves beside it) into Application
        // Support. Source-checkout trackers keep their repo-local files,
        // which is what dev runs expect. Appended after the env override
        // because the tracker reads the FIRST occurrence of a flag.
        if let resources = Bundle.main.resourceURL,
           trackerDir.resolvingSymlinksInPath().path
               .hasPrefix(resources.resolvingSymlinksInPath().path + "/") {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JevVoice", isDirectory: true)
            arguments += ["--calibration-file",
                          support.appendingPathComponent(".gaze_calibration.json").path]
        }
        return arguments
    }

    /// The main display's physical diagonal in inches from
    /// `CGDisplayScreenSize` (physical mm, not pixels); nil when
    /// CoreGraphics reports nothing so the flag stays off entirely.
    nonisolated static func mainDisplayDiagonalInch() -> Double? {
        let mm = CGDisplayScreenSize(CGMainDisplayID())
        guard mm.width > 0, mm.height > 0 else { return nil }
        return Double(hypot(mm.width, mm.height) / 25.4)
    }

    private func healthy() async -> Bool {
        await healthPayload() != nil
    }

    /// Who answered /health — `.stamped` carries the responder's
    /// `started_at` (stamped at process boot and never changing), while
    /// `.unstamped` is a live responder serving no stamp (a build too old
    /// to know it). nil means nothing answered: a dead port must never
    /// alias an unidentified responder — a dead port is free to spawn
    /// into, an unidentified one can't be proven different from the
    /// wedged tracker.
    private enum ResponderIdentity: Equatable {
        case stamped(String)
        case unstamped
    }

    /// The port's /health responder identity — see ResponderIdentity for
    /// the nil-vs-unstamped distinction the post-escalation adoption
    /// guard relies on.
    private func responderIdentity() async -> ResponderIdentity? {
        guard let payload = await healthPayload() else { return nil }
        guard let stamp = payload["started_at"] as? String else { return .unstamped }
        return .stamped(stamp)
    }

    /// One GET /health — the tracker's answer is {"ok":true,...}; any
    /// other 200 on the port is a squatter we must spawn past, not an
    /// adoptee; and a dead tracker's port going quiet must end the
    /// kill-path waits, not sit out a foreign server's uptime.
    private func healthPayload() async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["ok"] as? Bool == true
        else { return nil }
        return payload
    }

    nonisolated static func portableExtraArguments(_ text: String?, forceWasm: Bool) -> [String]? {
        guard let text else { return [] }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        for value in ["auto", "webgpu", "wasm"] {
            if words == ["--web-accelerator", Substring(value)] || words == [Substring("--web-accelerator=" + value)] {
                return forceWasm ? [] : ["--web-accelerator", value]
            }
        }
        return nil
    }

    nonisolated static var releaseProfile: String? {
        let marker = Bundle.main.object(forInfoDictionaryKey: "JevTrackerReleaseProfile")
#if JEV_PORTABLE_TRACKER
        return marker as? String ?? ""
#else
        return marker.map { $0 as? String ?? "" }
#endif
    }

    nonisolated static func portableDirectory(resources: URL?, profile: String) -> URL? {
        guard profile == "retinaface-v1", let resources else { return nil }
        let root = resources.resolvingSymlinksInPath().appendingPathComponent("EyeTracker")
        let fm = FileManager.default
        for name in ["package.json", "scripts/start-prod.cjs", "electron/main.cjs", "dist/index.html", "dist/.vite/manifest.json",
                     "node_modules/.bin/electron", "bin/node"] {
            let file = root.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path == file.path, fm.isReadableFile(atPath: file.path),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        }
        let metadata = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: metadata),
              let package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              package["jevTrackerProfile"] as? String == profile else { return nil }
        let electron = root.appendingPathComponent("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
            .resolvingSymlinksInPath()
        guard electron.path.hasPrefix(root.path + "/"), fm.isExecutableFile(atPath: electron.path) else { return nil }
        return root
    }

    static func trackerDirectory() -> URL? {
        if let releaseProfile { return portableDirectory(resources: Bundle.main.resourceURL, profile: releaseProfile) }
        let fm = FileManager.default
        // Bundled layout first: `make bundle-tracker` stages the tracker
        // at Contents/Resources/EyeTracker. The scripts/ launcher must
        // exist — a partially-staged bundle (a dir with no entry point)
        // must not shadow the working resolutions below.
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("EyeTracker"),
           ["scripts/start-prod.cjs", "scripts/dev.cjs"].contains(where: {
               fm.fileExists(atPath: bundled.appendingPathComponent($0).path)
           }) {
            return bundled
        }
        if let env = ProcessInfo.processInfo.environment["JARVIS_EYE_TRACKER_DIR"],
           fm.fileExists(atPath: env + "/package.json") {
            return URL(fileURLWithPath: env)
        }
        // Dev layout: <repo>/build/Jev Voice.app → <repo>/EyeTracking.
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EyeTracking")
        if fm.fileExists(atPath: sibling.appendingPathComponent("package.json").path) {
            return sibling
        }
        // Installed layout: the launch script symlinks the checkout into
        // app support, so a bundle living anywhere (~/jarvis-local etc.)
        // finds it without an env var. fileExists follows the symlink.
        let linked = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice/EyeTracking")
        if fm.fileExists(atPath: linked.appendingPathComponent("package.json").path) {
            return linked
        }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("EyeTracking")
        if let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("package.json").path) {
            return bundled
        }
        return nil
    }

    // MARK: - Test seams

    /// Drive the exit/retire paths without a real spawn — installs the
    /// child handle, spent budget, adoption flag and resolved dir a boot
    /// would have left behind. Tests pin `trackerDir` to a temp dir so
    /// the orphan sweep's pkill can never reach a real tracker.
    func installForTest(child proc: Process?, attempts: Int,
                        state: State, adopted: Bool = false,
                        trackerDir: URL? = nil) {
        process = proc
        self.attempts = attempts
        self.state = state
        self.adopted = adopted
        self.trackerDir = trackerDir
    }

    /// The live child's pid — what `handleExit(pid:)` matches against.
    var childPidForTest: Int32? { process?.processIdentifier }

    /// The current start-generation token — a respawn claim bumps it.
    var generationForTest: Int { startGeneration }

    /// Drive the screen-lock parking paths without owning the session's
    /// DistributedNotificationCenter — tests can't post there.
    func simulateScreenLock(_ locked: Bool) async {
        await handleScreenLockChange(locked)
    }

    /// Who holds the pause claim — the unlock path must never resurrect a
    /// pause the user set by hand.
    var pausedByLockForTest: Bool { pausedByLock }

    /// The persisted lock edge — what a `.running` transition re-parks from.
    var screenIsLockedForTest: Bool { screenIsLocked }
}

import Foundation

/// Launch-grant reconciliation for the pinned local Driver daemon.
///
/// `browser_prepare` with `strategy=existing_profile` — the only route to a
/// user's real logged-in Chromium profile — requires the daemon's immutable
/// `--grant existing-profile` launch flag. A running daemon cannot be granted
/// over MCP; only a `serve` restart carries it. Relaunching the daemon is a
/// launcher decision Jarvis makes for its own private driver — the consent
/// boundary that still protects the user is the per-window approval plus
/// `browser_prepare` at attach time.
enum CuaDaemonControl {
    /// Remembers that a daemon this process verified carried the grant. A
    /// `browser_prepare` authorization refusal clears it so the next app run
    /// reconciles again (a daemon that dies mid-session relaunches grantless).
    private static let configuredKey = "cuaDaemonExistingProfileGrantConfigured"
    /// Success is what latches — a reconcile that fails must retry on the
    /// next call, not stay poisoned for the process lifetime. The Task also
    /// single-flights concurrent callers (the check-then-set race would
    /// double `stop` and double `open -a` the daemon).
    private static var reconcileTask: Task<Bool, Never>?
    /// Callers arrive from several actors at once (each CuaConnection's
    /// connect, CuaSetup) — the check-and-set on `reconcileTask` must be
    /// atomic or two callers can both pass the nil check and double
    /// stop/open the daemon.
    private static let reconcileLock = NSLock()

    /// Reconciles once per process. Skips a restart only when the daemon is
    /// already listening AND this install previously verified it carries the
    /// grant — the driver exposes no grant query, so an unknown running daemon
    /// is restarted rather than guessed about.
    static func ensureExistingProfileGrant() async {
        // NSLock is unavailable in async contexts — the check-and-set lives
        // in synchronous claim/release helpers; only awaiting the task's
        // value stays on this path.
        let (task, owner) = claimReconcile()
        guard owner else {
            _ = await task.value
            return
        }
        let ok = await task.value
        if !ok { releaseReconcile(task) }
    }

    /// Atomic single-flight claim: returns the in-flight task for joiners,
    /// or mints and returns a fresh one for the caller that owns this
    /// reconcile.
    private static func claimReconcile() -> (task: Task<Bool, Never>, owner: Bool) {
        reconcileLock.lock()
        defer { reconcileLock.unlock() }
        if let task = reconcileTask { return (task, false) }
        let task = Task { await reconcile() }
        reconcileTask = task
        return (task, true)
    }

    /// Clear only OUR task — a caller that joined this one may have already
    /// cleared the slot, and a later caller may have replaced it; wiping a
    /// newer task would double the reconcile.
    private static func releaseReconcile(_ task: Task<Bool, Never>) {
        reconcileLock.lock()
        if reconcileTask == task { reconcileTask = nil }
        reconcileLock.unlock()
    }

    private static func reconcile() async -> Bool {
        let executable = CuaDependency.executable
        let listening = (try? await run(executable, ["status"], timeout: 3)) == true
        if listening && UserDefaults.standard.bool(forKey: configuredKey) { return true }
        if listening {
            // A daemon restart tombstones every session on live transports.
            // While any connection is up, defer — returning false clears the
            // single-flight so the next idle connect() retries — rather than
            // killing in-flight work underneath other lanes.
            guard CuaConnection.liveConnectionCount == 0 else { return false }
            // Unknown grant state; `serve` grants are immutable after launch.
            _ = try? await run(executable, ["stop"], timeout: 10)
        }
        // `open -a` is the route the driver's own mcp proxy uses to launch the
        // daemon — it keeps TCC attribution on the CuaDriver app bundle.
        let bundle = executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // .app
        guard (try? await run(URL(fileURLWithPath: "/usr/bin/open"),
                ["-n", "-g", bundle.path, "--args", "serve", "--grant", "existing-profile"],
                timeout: 10)) == true else { return false }
        // Bounded readiness wait: 30s wall-clock ceiling. Each status check
        // carries its own 2s timeout, so without a cap the attempt budget
        // could stretch to minutes when the daemon is stuck launching.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if (try? await run(executable, ["status"], timeout: 2)) == true {
                UserDefaults.standard.set(true, forKey: configuredKey)
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Called when `browser_prepare` reports the daemon was never granted.
    /// Clears the verified flag so the next app run reconciles again.
    static func markGrantUnconfirmed() {
        UserDefaults.standard.set(false, forKey: configuredKey)
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Timeout and termination fire on different queues; the lock makes
            // check-and-set atomic so the continuation resumes exactly once.
            let resumeLock = NSLock()
            var resumed = false
            let finish: (Bool) -> Void = { ok in
                resumeLock.lock()
                guard !resumed else { resumeLock.unlock(); return }
                resumed = true
                resumeLock.unlock()
                continuation.resume(returning: ok)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                finish(false)
            }
            process.terminationHandler = { p in finish(p.terminationStatus == 0) }
            do { try process.run() } catch { finish(false) }
        }
    }
}

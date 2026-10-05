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
    private static var reconciled = false

    /// Reconciles once per process. Skips a restart only when the daemon is
    /// already listening AND this install previously verified it carries the
    /// grant — the driver exposes no grant query, so an unknown running daemon
    /// is restarted rather than guessed about.
    static func ensureExistingProfileGrant() async {
        if reconciled { return }
        reconciled = true
        let executable = CuaDependency.executable
        let listening = (try? await run(executable, ["status"], timeout: 3)) == true
        if listening && UserDefaults.standard.bool(forKey: configuredKey) { return }
        if listening {
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
                timeout: 10)) == true else { return }
        for _ in 0..<100 {
            if (try? await run(executable, ["status"], timeout: 2)) == true {
                UserDefaults.standard.set(true, forKey: configuredKey)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
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

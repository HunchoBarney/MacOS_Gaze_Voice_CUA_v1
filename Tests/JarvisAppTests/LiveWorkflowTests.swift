import AppKit
import XCTest
@testable import Jarvis
import JarvisCore

/// Physical/desktop tests — they mutate the real machine. Each is gated on
/// an explicit flag and must run through `scripts/with-desktop-lock.py`:
///
///   JARVIS_APP_CUA_SOCKET — path to the RUNNING APP's daemon socket
///       (the `*.sock` in the app's `jarvis-cua-*` directory in $TMPDIR).
///       Driver calls then
///       execute under the app's TCC identity — real launches, real windows,
///       real raises.
///
///   JARVIS_LIVE_INPUT=1 — posts synthetic Fn `flagsChanged` events through
///       the session event tap a real `FnInputMonitor` installs. The test
///       host needs Accessibility/Input Monitoring. This exercises the
///       physical Fn path end to end minus the microphone.
///
/// Neither flag proves the mic/ASR hop — that's hardware. Everything else
/// in the voice hot path is real.
final class LiveWorkflowTests: XCTestCase {

    private static func controlsReady(_ kinds: Set<WindowControls.Kind>) -> Bool {
        kinds.contains(.close) && kinds.contains(.minimize)
    }

    private static func mayTerminate(pid: pid_t, preexisting: Set<pid_t>) -> Bool {
        !preexisting.contains(pid)
    }

    func testMinimizeHarnessReadinessAndCleanupOwnership() {
        XCTAssertFalse(Self.controlsReady([.minimize, .zoom]))
        XCTAssertFalse(Self.controlsReady([.close]))
        XCTAssertTrue(Self.controlsReady([.close, .minimize]))
        XCTAssertFalse(Self.mayTerminate(pid: 42, preexisting: [42]))
        XCTAssertTrue(Self.mayTerminate(pid: 43, preexisting: [42]))
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testDesktopArtifactsCannotOptIntoLiveActions() {
        XCTAssertFalse(Self.liveDesktopRequested(environment: [:]))
        XCTAssertFalse(Self.liveDesktopRequested(environment: ["JARVIS_LIVE_DESKTOP": "0"]))
        XCTAssertFalse(Self.liveDesktopRequested(environment: ["JARVIS_APP_CUA_SOCKET": ""]))
        XCTAssertTrue(Self.liveDesktopRequested(environment: ["JARVIS_LIVE_DESKTOP": "1"]))
        XCTAssertTrue(Self.liveDesktopRequested(environment: ["JARVIS_APP_CUA_SOCKET": "/explicit/test.sock"]))
    }

    private func socketPath() async throws -> String {
        if let explicit = env["JARVIS_APP_CUA_SOCKET"], !explicit.isEmpty {
            return explicit
        }
        // The running app keeps its live socket in a jarvis-cua-* directory
        // in $TMPDIR. A crashed run leaves its directory and socket file
        // behind, so take the newest socket that still accepts a connection.
        let tmp = NSTemporaryDirectory()
        if let found = try? FileManager.default.contentsOfDirectory(atPath: tmp)
            .filter({ $0.hasPrefix("jarvis-cua-") })
            .compactMap({ CuaSocketDirectory.liveSocket(in: tmp + $0) })
            .filter(Self.acceptsConnections)
            .max(by: { Self.modified($0) < Self.modified($1) }) {
            return found
        }
        // Nothing running — mint a daemon in this process. Driver calls then
        // run under the TEST host's TCC identity, so grant-dependent tools
        // may refuse; launch/list/activate paths still exercise for real.
        return try await CuaDaemonHost.shared.socket()
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    private static func acceptsConnections(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func liveDesktopRequested(environment: [String: String]) -> Bool {
        environment["JARVIS_LIVE_DESKTOP"] == "1"
            || environment["JARVIS_APP_CUA_SOCKET"].map { !$0.isEmpty } == true
    }

    private func requireLiveFlag() throws {
        guard Self.liveDesktopRequested(environment: env) else {
            throw XCTSkip("Live desktop tests require explicit opt-in — set JARVIS_LIVE_DESKTOP=1")
        }
    }

    /// "Open Notes" end-to-end against the real daemon: resolve → launch →
    /// materialize → raise → verify. The regression the user reported —
    /// a cold-launched app settling windowless — is exactly what this
    /// catches. Independently verifies the window via a fresh list_windows.
    func testLiveOpenNotesMaterializesWindow() async throws {
        try requireLiveFlag()
        let socket = try await socketPath()
        let conn = CuaConnection()
        try await conn.connect(socket: socket)
        defer { Task { await conn.close() } }

        let notesWasRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.apple.Notes" }
        defer {
            // Restore the desktop — quit only what the test started.
            if !notesWasRunning,
               let app = NSWorkspace.shared.runningApplications
                    .first(where: { $0.bundleIdentifier == "com.apple.Notes" }) {
                _ = app.terminate()
            }
        }

        // Sessions must be explicitly started to outlive the task burst —
        // an auto-minted label ends when its tool loop finishes.
        let session = "livetest-\(Int(Date().timeIntervalSince1970))"
        _ = try await conn.call("start_session", arguments: ["session": .string(session)])
        defer { Task { _ = try? await conn.call("end_session", arguments: ["session": .string(session)]) } }

        let loop = DriveLoop(
            call: { tool, args in try await conn.call(tool, arguments: args) },
            choose: { _, _ in nil },
            ask: nil, granted: { true })
        let result = await loop.run(DriveTask(goal: "open Notes",
                                              foreground: true),
                                    session: session)
        XCTAssertEqual(result.status, .done, "open Notes should settle done, got \(result.status): \(result.blockedReason ?? "")")
        XCTAssertTrue(result.dispatchedEffect)
        guard let pid = result.pid else {
            return XCTFail("no pid — the app did not launch")
        }

        // Independent postcondition: a fresh inventory shows the window —
        // "the process runs" is not "the user can see it".
        var found = false
        for _ in 0..<10 {
            let list = try await conn.call("list_windows",
                                           arguments: ["pid": .number(Double(pid)),
                                                       "session": .string(session)])
            let windows = list["structuredContent"]?["windows"]?.array
                ?? list["windows"]?.array ?? []
            if windows.contains(where: {
                $0["is_on_screen"] != .bool(false) && !($0["title"]?.string ?? "").isEmpty
            }) { found = true; break }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(found || result.windowID != nil,
                      "Notes ran but no usable window ever materialized — the materialize/activate path is broken")
    }

    /// "Search google for X" resolves to the engine URL — the routing fix.
    /// Asserts the resolution only; the actual navigation needs a bound
    /// browser and stays a manual check (noisy to automate).
    func testLiveSearchGoogleResolvesToEngine() async throws {
        try requireLiveFlag()
        let socket = try await socketPath()
        let conn = CuaConnection()
        try await conn.connect(socket: socket)
        defer { Task { await conn.close() } }

        let session = "livetest-resolve-\(Int(Date().timeIntervalSince1970))"
        _ = try await conn.call("start_session", arguments: ["session": .string(session)])
        defer { Task { _ = try? await conn.call("end_session", arguments: ["session": .string(session)]) } }
        let apps = try await conn.call("list_apps",
                                       arguments: ["session": .string(session)])
        let rows = apps["structuredContent"]?["apps"]?.array ?? apps["apps"]?.array ?? []
        let resolution = DriveLoop.resolveFastLane(
            goal: "search google for cute dogs",
            apps: rows,
            frontmostBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard case .navigateURL(let url)? = resolution?.action?.body else {
            return XCTFail("'search google for X' must resolve to a navigation URL, got \(String(describing: resolution))")
        }
        XCTAssertTrue(url.hasPrefix("https://www.google.com/search?q="))
    }

    /// "Search for cute dogs" — the reported UX failure: an unqualified
    /// search while a browser is frontmost must not fall into the generic
    /// loop hunting an app literally named "search for cute dogs". Asserts
    /// the fast-lane resolution only — navigation itself is verified
    /// manually (it would churn the user's browser).
    func testLiveBareSearchDoesNotBindAnApp() async throws {
        try requireLiveFlag()
        let socket = try await socketPath()
        let conn = CuaConnection()
        try await conn.connect(socket: socket)
        defer { Task { await conn.close() } }

        let session = "livetest-search-\(Int(Date().timeIntervalSince1970))"
        _ = try await conn.call("start_session", arguments: ["session": .string(session)])
        defer { Task { _ = try? await conn.call("end_session", arguments: ["session": .string(session)]) } }
        let apps = try await conn.call("list_apps",
                                       arguments: ["session": .string(session)])
        let rows = apps["structuredContent"]?["apps"]?.array ?? apps["apps"]?.array ?? []
        let resolution = DriveLoop.resolveFastLane(
            goal: "search for cute dogs",
            apps: rows,
            frontmostBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard case .webSearch(let url)? = resolution?.action?.body else {
            return XCTFail("bare 'search for X' must resolve webSearch — got \(String(describing: resolution?.action?.body))")
        }
        XCTAssertTrue(url.contains("google.com/search") && url.contains("cute%20dogs"),
                      "bare search should target the engine results URL, got \(url)")
    }

    /// The live repro of the reported failure: "search for cute dogs" with
    /// literal text — the generic loop must refuse fast (no app by that
    /// name), not spin. Mirrors what the app task should have done.
    func testLiveBareSearchSettlesFast() async throws {
        try requireLiveFlag()
        let socket = try await socketPath()
        let conn = CuaConnection()
        try await conn.connect(socket: socket)
        defer { Task { await conn.close() } }
        let session = "livetest-bare-\(Int(Date().timeIntervalSince1970))"
        _ = try await conn.call("start_session", arguments: ["session": .string(session)])
        defer { Task { _ = try? await conn.call("end_session", arguments: ["session": .string(session)]) } }

        let loop = DriveLoop(
            call: { tool, args in try await conn.call(tool, arguments: args) },
            choose: { _, _ in nil }, ask: nil, granted: { true })
        var task = DriveTask(goal: "search for cute dogs", foreground: false)
        task.values["text"] = "cute dogs"
        let started = Date()
        let result = await loop.run(task, session: session)
        print("RESULT: \(result.status) in \(Int(Date().timeIntervalSince(started) * 1000))ms reason=\(result.blockedReason ?? "-")")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20,
                          "a bare search must settle in seconds, not minutes")
    }

    /// Synthetic Fn through the REAL tap: posts flagsChanged events to the
    /// HID tap, which every session tap (including ours) observes. This is
    /// the physical "press and release Fn" the reducer can't prove alone.
    @MainActor
    func testLiveSyntheticFnDrivesCapture() async throws {
        guard env["JARVIS_LIVE_INPUT"] == "1" else {
            throw XCTSkip("set JARVIS_LIVE_INPUT=1 with the test host in Accessibility")
        }
        let monitor = FnInputMonitor()
        monitor.canBegin = { true }
        let began = expectation(description: "Fn down begins capture")
        let finished = expectation(description: "Fn up finishes capture")
        var actions: [FnInputState.Action] = []
        monitor.onAction = { action in
            actions.append(action)
            if action == .begin { began.fulfill() }
            if action == .finish { finished.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }

        // A beat for the tap to install before events fly.
        try await Task.sleep(for: .milliseconds(300))

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return XCTFail("no HID event source — Accessibility missing?")
        }
        // Fn press: the session tap reads flagsChanged(key=63, fn=true).
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: false) else {
            return XCTFail("could not construct Fn events")
        }
        down.flags = .maskSecondaryFn
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(250))
        up.flags = []
        up.post(tap: .cghidEventTap)

        await fulfillment(of: [began, finished], timeout: 4)
        XCTAssertEqual(actions.prefix(2), [.begin, .finish],
                       "synthetic Fn should drive the same begin/finish as a physical press")
    }

    /// The `wc:` lane end-to-end on Calculator: host-side AX reads the
    /// traffic lights the driver's element snapshot can't see, AXPress
    /// minimizes without raising, and `list_windows` verifies the window
    /// actually left the screen — the "minimize Devin" failure class,
    /// proven on a real app under the test host's AX identity.
    func testLiveWindowControlsMinimizeCalculator() async throws {
        try requireLiveFlag()
        let socket = try await socketPath()
        let conn = CuaConnection()
        try await conn.connect(socket: socket)
        defer { Task { await conn.close() } }

        let session = "livetest-wc-\(Int(Date().timeIntervalSince1970))"
        _ = try await conn.call("start_session", arguments: ["session": .string(session)])
        defer { Task { _ = try? await conn.call("end_session", arguments: ["session": .string(session)]) } }

        let preexisting = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator")
            .map(\.processIdentifier))
        let launched = try await conn.call("launch_app", arguments: [
            "bundle_id": .string("com.apple.calculator"),
            "session": .string(session)])
        let content = launched["structuredContent"] ?? launched
        guard let pidValue = content["pid"], case .number(let pidNum) = pidValue else {
            return XCTFail("launch_app returned no pid: \(launched)")
        }
        let pid = pid_t(pidNum)
        defer {
            // Unhide/reactivate; quit only an instance absent before launch.
            if let app = NSRunningApplication(processIdentifier: pid) {
                _ = app.unhide(); app.activate(options: [])
                if Self.mayTerminate(pid: pid, preexisting: preexisting) { _ = app.terminate() }
            }
        }

        // The AX session needs a beat after launch before the window and
        // its controls are queryable.
        var buttons: [WindowControls.Button] = []
        for _ in 0..<20 {
            buttons = WindowControls.buttons(pid: pid)
            if Self.controlsReady(Set(buttons.map(\.kind))) { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        let kinds = Set(buttons.map(\.kind))
        XCTAssertTrue(kinds.contains(.close), "close button missing — got \(kinds)")
        XCTAssertTrue(kinds.contains(.minimize), "minimize button missing — got \(kinds)")

        guard WindowControls.press(.minimize, pid: pid) else {
            return XCTFail("AXPress on the minimize light was refused")
        }
        // Verify from the driver's own inventory — the row leaves the
        // screen or reports minimized; either is an honest settle.
        var gone = false
        for _ in 0..<15 {
            let list = try await conn.call("list_windows", arguments: [
                "pid": .number(pidNum), "session": .string(session)])
            let windows = list["structuredContent"]?["windows"]?.array
                ?? list["windows"]?.array ?? []
            let onScreen = windows.contains {
                $0["is_on_screen"] != .bool(false)
                    && $0["is_minimized"] != .bool(true)
            }
            if !onScreen { gone = true; break }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(gone,
                      "AXPress minimize landed but list_windows still shows an on-screen window — verification path is lying")
    }
}

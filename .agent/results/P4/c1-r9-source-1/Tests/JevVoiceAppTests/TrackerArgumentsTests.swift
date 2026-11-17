import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: `TrackerHost.trackerArguments` builds the child argv without
/// spawning — script selection keys off the checkout on disk, geometry
/// comes from UserDefaults (Settings edits need no rebuild), the wasm
/// session fallback and `JARVIS_EYE_TRACKER_ARGS` land last, in that
/// order.
final class TrackerArgumentsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var trackerDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "TrackerArgumentsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        trackerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracker-args-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trackerDir.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        if let trackerDir { try? FileManager.default.removeItem(at: trackerDir) }
        try super.tearDownWithError()
    }

    private func args(useProdRenderer: Bool = false,
                      forceWasm: Bool = false,
                      environment: [String: String] = [:],
                      hostPid: Int32 = 4242) -> [String] {
        TrackerHost.trackerArguments(trackerDir: trackerDir,
                                     useProdRenderer: useProdRenderer,
                                     forceWasm: forceWasm,
                                     defaults: defaults,
                                     environment: environment,
                                     hostPid: hostPid)
    }

    /// The value following a flag, nil when the flag is absent — argv
    /// pairs are what the tracker actually parses.
    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private func touchDevScript() {
        FileManager.default.createFile(
            atPath: trackerDir.appendingPathComponent("scripts/dev.cjs").path,
            contents: Data())
    }

    // MARK: - Script selection

    /// A checkout carrying scripts/dev.cjs boots through the vite+electron
    /// wrapper.
    func testDevScriptWhenDevCjsExists() {
        touchDevScript()
        XCTAssertEqual(args().first, "scripts/dev.cjs")
    }

    /// A checkout without dev.cjs falls back to the plain start wrapper —
    /// the stat keys off the trackerDir handed in.
    func testStartScriptFallbackWhenDevCjsMissing() {
        XCTAssertEqual(args().first, "scripts/start.cjs")
    }

    /// The prod renderer never stats dev.cjs — start-prod wins whether or
    /// not the dev wrapper exists.
    func testProdScriptIgnoresDevCjsPresence() {
        XCTAssertEqual(args(useProdRenderer: true).first, "scripts/start-prod.cjs")
        touchDevScript()
        XCTAssertEqual(args(useProdRenderer: true).first, "scripts/start-prod.cjs")
    }

    /// The hosted-mode markers always ride right behind the script —
    /// read-only API on, tracker tray off.
    func testExternalApiAndNoTrayAlwaysLead() {
        for arguments in [args(), args(useProdRenderer: true)] {
            XCTAssertEqual(Array(arguments.dropFirst().prefix(2)),
                           ["--external-api", "--no-tray"])
        }
    }

    /// The death watchdog always carries the given host pid — the
    /// tracker self-quits when the pid is gone, so a crashed or
    /// force-quit app can't leave a tracker holding the camera.
    func testHostPidAlwaysEmitted() {
        XCTAssertEqual(value(after: "--host-pid", in: args(hostPid: 4242)), "4242")
        XCTAssertEqual(value(after: "--host-pid", in: args(useProdRenderer: true, hostPid: 777)), "777")
    }

    // MARK: - Geometry defaults

    /// An explicit display size wins over display detection.
    func testDisplaySizeOverrideEmitsExactValue() {
        defaults.set(31.5, forKey: "trackerDisplaySizeInch")
        XCTAssertEqual(value(after: "--display-size-inch", in: args()), "31.5")
    }

    /// No default → the detected physical diagonal serves when
    /// CoreGraphics knows it; the flag stays off entirely when it
    /// doesn't. Either way no bogus "0" reaches the tracker.
    func testDisplaySizeUnsetFallsBackToDetection() {
        let arguments = args()
        if let detected = TrackerHost.mainDisplayDiagonalInch() {
            XCTAssertEqual(value(after: "--display-size-inch", in: arguments),
                           String(format: "%.2f", detected))
        } else {
            XCTAssertNil(value(after: "--display-size-inch", in: arguments))
        }
    }

    /// A non-positive default is "unset" — it must not emit itself and
    /// must not mask detection.
    func testNonPositiveDisplaySizeTreatedAsUnset() {
        for value in [0.0, -2.5] {
            defaults.set(value, forKey: "trackerDisplaySizeInch")
            let emitted = self.value(after: "--display-size-inch", in: args())
            XCTAssertNotEqual(emitted, "\(value)")
            if let detected = TrackerHost.mainDisplayDiagonalInch() {
                XCTAssertEqual(emitted, String(format: "%.2f", detected))
            } else {
                XCTAssertNil(emitted)
            }
        }
    }

    /// Camera FOV only emits when a positive default exists.
    func testCameraFovFlag() {
        XCTAssertNil(value(after: "--camera-fov", in: args()))
        defaults.set(87, forKey: "trackerCameraFovDeg")
        XCTAssertEqual(value(after: "--camera-fov", in: args()), "87")
        defaults.set(0, forKey: "trackerCameraFovDeg")
        XCTAssertNil(value(after: "--camera-fov", in: args()))
    }

    /// binocular-screen is the tuned production projection — always
    /// passed unless the defaults key overrides it for an experiment.
    func testProjectionModeDefaultAndOverride() {
        XCTAssertEqual(value(after: "--gaze-projection-mode", in: args()),
                       "binocular-screen")
        defaults.set("", forKey: "trackerProjectionMode")
        XCTAssertEqual(value(after: "--gaze-projection-mode", in: args()),
                       "binocular-screen")
        defaults.set("monocular", forKey: "trackerProjectionMode")
        XCTAssertEqual(value(after: "--gaze-projection-mode", in: args()),
                       "monocular")
    }

    /// Wasm thread tuning only emits when set.
    func testWasmThreadsFlag() {
        XCTAssertNil(value(after: "--wasm-threads", in: args()))
        defaults.set(4, forKey: "trackerWasmThreads")
        XCTAssertEqual(value(after: "--wasm-threads", in: args()), "4")
    }

    // MARK: - Wasm fallback + env escape hatch

    /// The wedged-WebGPU session fallback appends the provider switch and
    /// the fps cap as a contiguous pair, after the geometry flags.
    func testForceWasmAppendsProviderAndFpsCap() {
        let arguments = args(forceWasm: true)
        guard let wasmIndex = arguments.firstIndex(of: "--web-accelerator") else {
            return XCTFail("missing --web-accelerator")
        }
        XCTAssertEqual(Array(arguments[wasmIndex...].prefix(4)),
                       ["--web-accelerator", "wasm", "--gaze-max-fps", "10"])
        // It lands after the projection flag, not before it.
        XCTAssertGreaterThan(wasmIndex,
                             arguments.firstIndex(of: "--gaze-projection-mode")!)
        XCTAssertFalse(args().contains("--web-accelerator"),
                       "a healthy boot never pins wasm")
    }

    /// JARVIS_EYE_TRACKER_ARGS is the raw escape hatch — split on spaces
    /// and appended LAST, after even the wasm fallback.
    func testEnvArgsAppendLast() {
        let arguments = args(
            forceWasm: true,
            environment: ["JARVIS_EYE_TRACKER_ARGS": "--cal-override 0.5 --extra"])
        XCTAssertEqual(Array(arguments.suffix(3)),
                       ["--cal-override", "0.5", "--extra"])
        XCTAssertEqual(Array(arguments.suffix(5)),
                       ["--gaze-max-fps", "10", "--cal-override", "0.5", "--extra"])
    }

    /// No env, or an empty one, appends nothing.
    func testEnvAbsentAddsNothing() {
        let baseline = args()
        XCTAssertEqual(args(environment: ["JARVIS_EYE_TRACKER_ARGS": ""]), baseline)
        XCTAssertEqual(args(environment: ["OTHER": "--bogus 1"]), baseline)
    }

    // MARK: - Bundled-tracker calibration redirect

    /// A tracker outside the app bundle keeps its checkout-local
    /// calibration — no --calibration-file flag reaches argv.
    func testSourceCheckoutGetsNoCalibrationRedirect() {
        XCTAssertNil(value(after: "--calibration-file", in: args()))
    }

    /// A tracker staged inside Contents/Resources can't write beside
    /// itself once the bundle is signed — the argv must redirect the
    /// calibration file (and settings.json, which follows it) into the
    /// app's Application Support directory.
    func testBundledTrackerRedirectsCalibrationIntoAppSupport() throws {
        guard let resources = Bundle.main.resourceURL else {
            throw XCTSkip("test host has no resource bundle")
        }
        let bundled = resources.appendingPathComponent("EyeTracker", isDirectory: true)
        let arguments = TrackerHost.trackerArguments(trackerDir: bundled,
                                                     useProdRenderer: true,
                                                     forceWasm: false,
                                                     defaults: defaults,
                                                     environment: [:],
                                                     hostPid: 4242)
        let calibration = value(after: "--calibration-file", in: arguments)
        XCTAssertNotNil(calibration)
        XCTAssertTrue(calibration!.contains("Application Support/JevVoice"))
        XCTAssertTrue(calibration!.hasSuffix(".gaze_calibration.json"))
        // The env escape hatch still wins — it parses before this flag.
        let overridden = TrackerHost.trackerArguments(
            trackerDir: bundled,
            useProdRenderer: true,
            forceWasm: false,
            defaults: defaults,
            environment: ["JARVIS_EYE_TRACKER_ARGS": "--calibration-file /tmp/dev.json"],
            hostPid: 4242)
        XCTAssertEqual(value(after: "--calibration-file", in: overridden), "/tmp/dev.json")
    }

    /// A bundled tracker prefers its own staged bin/node over every
    /// system resolution — the payload ships node so a packaged app has
    /// no external dependency.
    func testNodeBinaryPrefersBundledPayload() throws {
        let staged = trackerDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let node = staged.appendingPathComponent("node")
        FileManager.default.createFile(atPath: node.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        XCTAssertEqual(TrackerHost.nodeBinary(environment: [:], trackerDir: trackerDir), node)
    }

    /// A tracker dir without a staged node falls through to the system
    /// probes exactly as before.
    func testNodeBinaryFallsThroughWithoutBundled() {
        let resolved = TrackerHost.nodeBinary(environment: [:], trackerDir: trackerDir)
        if let resolved {
            XCTAssertFalse(resolved.path.hasPrefix(trackerDir.path),
                           "no staged node exists — resolution must not invent one")
        }
    }

    /// Full composition pinned end to end — script, markers, geometry,
    /// wasm fallback, env hatch, in argv order.
    func testFullArgvComposition() {
        touchDevScript()
        defaults.set(31.5, forKey: "trackerDisplaySizeInch")
        defaults.set(87, forKey: "trackerCameraFovDeg")
        defaults.set("monocular", forKey: "trackerProjectionMode")
        defaults.set(4, forKey: "trackerWasmThreads")

        XCTAssertEqual(
            args(forceWasm: true,
                 environment: ["JARVIS_EYE_TRACKER_ARGS": "--flag 1"]),
            ["scripts/dev.cjs", "--external-api", "--no-tray",
             "--host-pid", "4242",
             "--display-size-inch", "31.5",
             "--camera-fov", "87",
             "--gaze-projection-mode", "monocular",
             "--wasm-threads", "4",
             "--web-accelerator", "wasm", "--gaze-max-fps", "10",
             "--flag", "1"])
    }
}

import AppKit
import XCTest
@testable import Jarvis
import JarvisCore

extension AppResolver {
    /// A resolver that knows only the apps a test names: `running` stands
    /// in for NSWorkspace's process list, `installed` for LaunchServices
    /// and the Applications folders. Nothing on this Mac changes what it
    /// resolves.
    static func fixture(running: [App] = [], installed: [App] = []) -> AppResolver {
        fixture(listApps: { running }, installed: installed)
    }

    /// The same, for a test whose running list is computed per call.
    static func fixture(exactBundleApps: @escaping (String) -> [App] = { _ in [] },
                        listApps: @escaping () async throws -> [App],
                        installed: [App] = []) -> AppResolver {
        AppResolver(exactBundleApps: exactBundleApps, listApps: listApps, installedApp: { query in
            let needle = query.lowercased()
            return installed.first { $0.bundle?.lowercased() == needle }
                ?? installed.first { $0.name.lowercased() == needle }
                ?? installed.filter { $0.name.lowercased().contains(needle) }
                    .min { $0.name.count < $1.name.count }
        })
    }
}

extension WindowControls.Attributes {
    /// No window answers and Stage Manager is off, whatever this Mac's
    /// preferences say.
    static var inert: Self {
        Self(minimized: { _, _ in nil }, setMinimized: { _, _, _ in false },
             fullScreen: { _, _ in nil }, setFullScreen: { _, _, _ in false },
             raise: { _, _ in false }, stageManager: { false })
    }
}

extension DesktopSpaceSwitch.System {
    /// No Mission Control to read or open, no display, no space layout
    /// and no enabled shortcut, so a desktop lane refuses before touching
    /// the Dock or posting a key.
    static var inert: Self {
        Self(roots: { [] }, children: { _ in nil }, attr: { _, _ in nil },
             pressable: { _ in false }, press: { _ in false }, displayID: { nil },
             labels: { nil }, openMissionControl: { throw CocoaError(.featureUnsupported) },
             pause: {}, watchSpaceChange: { { _ in false } }, layout: { nil },
             shortcutEnabled: { _ in false })
    }
}

extension DriveLoop {
    /// `DriveLoop.init` with every Mac-facing default replaced by an inert
    /// one: no running or installed apps, no frontmost app or window, no
    /// AX reads, no media keys, no app activation and no Mission Control.
    /// A test states what it needs by passing the seam; nothing it doesn't
    /// name is read from the Mac running the suite. The labels mirror the
    /// init, so a call site switches by name alone.
    static func inert(
        call: @escaping Call, choose: @escaping Choose,
        ask: AskFn?, granted: @escaping () -> Bool,
        explicitConsent: Bool = true,
        callRead: Call? = nil,
        directSession: String? = nil,
        onDictationRequest: ((Bool) async -> Bool)? = nil,
        resolver: AppResolver = .fixture(),
        config: Config = .default,
        focusLease: AsyncLease? = nil,
        focusedTextTarget: @escaping @Sendable (Int, Int) async -> FocusedTextBinding? = { _, _ in nil },
        nativeFocusedWindowID: @escaping @Sendable (Int) async -> Int? = { _ in nil },
        nativeForegroundWindow: @escaping @Sendable (Int) async -> Int? = { _ in nil },
        nativeEvent: @escaping @Sendable (VoiceCommandTrace.Stage) async -> Void = { _ in },
        nativeTextEvent: @escaping @Sendable (FocusedTextBinding.Insertion) async -> Void = { _ in },
        postMediaKey: @escaping (MediaKeys.Key) -> Bool = { _ in true },
        activateApp: @escaping (Int) -> Void = { _ in },
        appIsHidden: @escaping (Int) -> Bool = { _ in false },
        unhideApp: @escaping (Int) -> Bool = { _ in false },
        activateRestoredApp: @escaping (Int, String?) -> Void = { _, _ in },
        foregroundAppLauncher: ((String) async throws -> Int)? = nil,
        observeLaunchedPID: @escaping (String) async -> Int? = { _ in nil },
        gaze: (() async throws -> GazeSample)? = nil,
        gazeCommit: (() async -> (IntentCandidate, Double)?)? = nil,
        windowControlButtons: ((pid_t) -> [WindowControls.Button])? = { _ in [] },
        windowControlPress: ((WindowControls.Kind, pid_t) -> Bool)? = { _, _ in false },
        windowControlButtonsInWindow: ((pid_t, Int) -> [WindowControls.Button])? = nil,
        windowControlPressInWindow: ((WindowControls.Kind, pid_t, Int) -> Bool)? = nil,
        windowAttributes: WindowControls.Attributes = .inert,
        desktopSpaces: DesktopSpaceSwitch.System = .inert,
        overlayDispatch: ((FastAction.OverlayVerb,
                           [(frame: CGRect, label: String)],
                           CGPoint?) async -> DriveResult?)? = nil,
        frontmostBundleID: @escaping () -> String? = { nil },
        frontmostPID: @escaping () -> Int? = { nil },
        frontmostWindowID: @escaping () -> Int? = { nil },
        resurrector: SessionResurrector = .shared,
        nativeReadOnly: @escaping NativeWindowObservation.Read = { _, _ in nil },
        nativeScrollRead: @escaping NativeWindowObservation.ScrollRead = { _, _, _, _ in nil },
        nativeScrollControl: @escaping NativeWindowObservation.ScrollControl = { _, _, _ in .unavailable },
        scrollContinuation: NativeWindowObservation.ScrollViewport? = nil,
        freshScrollContinuation: Bool = false,
        scrollContinuationIsCurrent: (@Sendable () async -> Bool)? = nil,
        onVerifiedScroll: (@Sendable (NativeWindowObservation.VerifiedScroll) async -> Void)? = nil,
        guide: GuideSession? = nil,
        feed: @escaping (String) -> Void = { _ in }
    ) -> DriveLoop {
        DriveLoop(call: call, choose: choose, ask: ask, granted: granted,
                  explicitConsent: explicitConsent, callRead: callRead,
                  directSession: directSession, onDictationRequest: onDictationRequest,
                  resolver: resolver, config: config, focusLease: focusLease,
                  focusedTextTarget: focusedTextTarget,
                  nativeFocusedWindowID: nativeFocusedWindowID,
                  nativeForegroundWindow: nativeForegroundWindow,
                  nativeEvent: nativeEvent, nativeTextEvent: nativeTextEvent,
                  postMediaKey: postMediaKey, activateApp: activateApp,
                  appIsHidden: appIsHidden, unhideApp: unhideApp,
                  activateRestoredApp: activateRestoredApp,
                  foregroundAppLauncher: foregroundAppLauncher,
                  observeLaunchedPID: observeLaunchedPID,
                  gaze: gaze, gazeCommit: gazeCommit,
                  windowControlButtons: windowControlButtons,
                  windowControlPress: windowControlPress,
                  windowControlButtonsInWindow: windowControlButtonsInWindow,
                  windowControlPressInWindow: windowControlPressInWindow,
                  windowAttributes: windowAttributes, desktopSpaces: desktopSpaces,
                  overlayDispatch: overlayDispatch,
                  frontmostBundleID: frontmostBundleID, frontmostPID: frontmostPID,
                  frontmostWindowID: frontmostWindowID, resurrector: resurrector,
                  nativeReadOnly: nativeReadOnly, nativeScrollRead: nativeScrollRead,
                  nativeScrollControl: nativeScrollControl,
                  scrollContinuation: scrollContinuation,
                  freshScrollContinuation: freshScrollContinuation,
                  scrollContinuationIsCurrent: scrollContinuationIsCurrent,
                  onVerifiedScroll: onVerifiedScroll, guide: guide, feed: feed)
    }
}

extension DictationDelivery {
    /// Delivery that reaches no app: nothing is inserted, pasted or
    /// deleted, and the pasteboard is never touched.
    static var inert: Self {
        Self(insertText: { _ in false }, pasteText: { _ in false }, deleteBackward: { _ in false })
    }
}

extension VoiceController {
    /// `VoiceController.init` with its Mac-facing defaults made inert: no
    /// frontmost app or focused window, every permission granted, no other
    /// app on the microphone, no microphone authorization prompt and no
    /// dictation reaching the pasteboard or keyboard. Labels mirror the
    /// init. The app-activation observer has no seam and stays live.
    static func inert(config: Config? = nil, speech: SpeechCapturing? = nil,
                      authorize: @escaping () async -> Bool = { false },
                      timings: VoiceTimings = VoiceTimings(),
                      frontmost: @escaping () -> String? = { nil },
                      focusedWindow: @escaping () -> (pid: Int, bundle: String?, windowID: Int)? = { nil },
                      cuaRuntime: VoiceTaskCoordinator? = nil,
                      dictation: DictationDelivering = DictationDelivery.inert,
                      speaker: SpeechSynthesizing? = nil,
                      permissionStatusReader: @escaping @Sendable () -> [Permission] = { [] },
                      otherAppUsesMicrophone: @escaping @Sendable () -> Bool = { false }) -> VoiceController {
        VoiceController(config: config, speech: speech, authorize: authorize, timings: timings,
                        frontmost: frontmost, focusedWindow: focusedWindow, cuaRuntime: cuaRuntime,
                        dictation: dictation, speaker: speaker,
                        permissionStatusReader: permissionStatusReader,
                        otherAppUsesMicrophone: otherAppUsesMicrophone)
    }
}

/// Config's init probes its key stores; these never reach the Keychain.
private struct NoKeys: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ apiKey: String) throws {}
    func delete() throws {}
}

extension XCTestCase {
    /// Points the eye-tracking feature switch (`TrackerControl.config`) at
    /// a Config on a suite only this test sees, and returns both. The
    /// shared Config persists to `UserDefaults.standard`, which every test
    /// process on the Mac reads.
    @MainActor
    func usePrivateTrackerConfig() -> (config: Config, defaults: UserDefaults) {
        let suite = "\(type(of: self)).tracker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let config = Config(defaults: defaults, keyStore: NoKeys(), openAIKeyStore: NoKeys(),
                            environment: [:])
        let saved = TrackerControl.config
        TrackerControl.config = { config }
        addTeardownBlock {
            await MainActor.run { TrackerControl.config = saved }
            defaults.removePersistentDomain(forName: suite)
        }
        return (config, defaults)
    }
}

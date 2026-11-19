import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case microphone = "Microphone"
    case camera = "Camera"
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"

    // Audio streams to the realtime API — no on-device recognizer grant
    // needed. The other three cover the rest of what the app touches:
    // Camera feeds the eye tracker (spawned children inherit this app's
    // TCC identity), Screen Recording covers the tracker's display reads
    // and computer-use screenshots, Accessibility drives Fn and input.
    static let allCases: [Permission] = [.microphone, .camera, .screenRecording, .accessibility]

    var id: String { rawValue }

    var purpose: String {
        switch self {
        case .microphone: return "hear your commands"
        case .camera: return "see your face for eye tracking"
        case .screenRecording: return "read the screen for gaze and computer control"
        case .accessibility: return "enable Fn and control your Mac"
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .camera: return "Privacy_Camera"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone:
            if #available(macOS 14, *) {
                return AVAudioApplication.shared.recordPermission == .granted
            }
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Whether the system will still show its own prompt for this permission.
    var canPrompt: Bool {
        switch self {
        case .microphone:
            if #available(macOS 14, *) {
                return AVAudioApplication.shared.recordPermission == .undetermined
            }
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        case .screenRecording:
            // No prompt API surfaces reliably pre-Sequoia — request()
            // registers the app in the pane and deep-links it, so the
            // honest button label is "Open settings", not "Allow".
            return false
        case .accessibility:
            return true
        }
    }

    static var missing: [Permission] { allCases.filter { !$0.isGranted } }

    /// Triggers the system prompt where one is still available, otherwise opens System Settings.
    @MainActor
    func request() async {
        guard !isGranted else { return }
        if self == .screenRecording {
            // CGRequestScreenCaptureAccess puts the app in the Screen
            // Recording list and can raise a one-time alert on newer macOS,
            // but it does not reliably prompt on older builds — so the
            // request is always paired with the pane deep link, which is
            // where the toggle actually lives.
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            openSystemSettings()
            return
        }
        guard canPrompt else {
            openSystemSettings()
            return
        }
        switch self {
        case .microphone:
            if #available(macOS 14, *) {
                _ = await AVAudioApplication.requestRecordPermission()
            } else {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            break // handled above — request + deep link
        }
    }

    @MainActor
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class PermissionStatusMonitor {
    private let read: @Sendable () -> [Permission]
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var stopped = false

    var isRefreshing: Bool { task != nil }

    init(read: @escaping @Sendable () -> [Permission] = { Permission.missing }) {
        self.read = read
    }

    func refresh(_ receive: @escaping @MainActor ([Permission]) -> Void) {
        guard !stopped, task == nil else { return }
        let generation = generation
        task = Task { [weak self, read] in
            let missing = await Task.detached(priority: .utility) { read() }.value
            guard let self else { return }
            self.task = nil
            guard !Task.isCancelled, !self.stopped, self.generation == generation else { return }
            receive(missing)
        }
    }

    func invalidate() {
        generation &+= 1
        task?.cancel()
    }

    func stop() {
        stopped = true
        invalidate()
    }
}

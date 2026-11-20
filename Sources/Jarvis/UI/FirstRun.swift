import AppKit
import AVFoundation
import SwiftUI

/// The first run: allow the microphone, allow Accessibility, then try a
/// command. Each permission step watches the system and moves on by itself
/// once the grant lands, so nobody has to come back and press anything.
@MainActor
final class FirstRunModel: ObservableObject {
    enum Step: CaseIterable {
        /// Explains the orange microphone dot. Shown only when Standby can
        /// actually run, so it stays hidden until a wake-word engine ships.
        case standbyIntro
        case microphone, accessibility, tryIt
    }

    enum Grant: Equatable { case notAsked, waiting, granted, refused }

    let steps: [Step]
    @Published private(set) var step: Step
    @Published private(set) var microphone: Grant = .notAsked
    @Published private(set) var accessibility: Grant = .notAsked
    /// Calculator opened while the try-it step was showing.
    @Published private(set) var triedIt = false

    // Probes and actions — production defaults; tests inject.
    var microphoneGrant: () -> Grant = FirstRunModel.systemMicrophoneGrant
    var accessibilityGranted: () -> Bool = { Permission.accessibility.isGranted }
    var requestMicrophone: () async -> Void = { await Permission.microphone.request() }
    var requestAccessibility: () async -> Void = { await Permission.accessibility.request() }
    var openSystemSettings: (Permission) -> Void = { $0.openSystemSettings() }

    init(policy: ListeningPolicy = .current) {
        steps = Step.allCases.filter { $0 != .standbyIntro || policy.showsStandbyIntro }
        step = steps[0]
    }

    /// "Step 2 of 3" — the intro screen isn't a numbered step.
    var position: (number: Int, of: Int)? {
        let numbered = steps.filter { $0 != .standbyIntro }
        guard let index = numbered.firstIndex(of: step) else { return nil }
        return (index + 1, numbered.count)
    }

    /// Re-reads the system. A grant that landed moves the user on.
    func refresh() {
        let mic = microphoneGrant()
        microphone = mic == .notAsked && microphone == .waiting ? .waiting : mic
        if accessibilityGranted() { accessibility = .granted }
        if step == .microphone, microphone == .granted { advance() }
        if step == .accessibility, accessibility == .granted { advance() }
    }

    func allow() {
        switch step {
        case .microphone:
            if microphone == .refused { openSystemSettings(.microphone); return }
            microphone = .waiting
            Task { await requestMicrophone(); refresh() }
        case .accessibility:
            accessibility = .waiting
            Task { await requestAccessibility(); refresh() }
        case .standbyIntro, .tryIt:
            advance()
        }
    }

    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    func applicationLaunched(bundleID: String?) {
        if step == .tryIt, bundleID == "com.apple.calculator" { triedIt = true }
    }

    nonisolated static func systemMicrophoneGrant() -> Grant {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .refused
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }
}

struct FirstRunView: View {
    @StateObject private var model = FirstRunModel()
    @ObservedObject var config: Config
    var finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let position = model.position {
                Text("Step \(position.number) of \(position.of)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
            content
            Spacer(minLength: 24)
            footer
        }
        .padding(32)
        .frame(width: 520, height: 400, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            model.applicationLaunched(bundleID: app?.bundleIdentifier)
        }
        .onChange(of: model.step) { announce(title) }
    }

    private var title: String {
        switch model.step {
        case .standbyIntro: return "Jarvis listens for “Hey Jarvis”"
        case .microphone: return "Let Jarvis hear you"
        case .accessibility: return "Let Jarvis use your Mac"
        case .tryIt: return model.triedIt ? "That worked" : "Try it"
        }
    }

    @ViewBuilder private var content: some View {
        Text(title).font(.system(size: 26, weight: .semibold)).padding(.bottom, 12)
        switch model.step {
        case .standbyIntro:
            HStack(spacing: 10) {
                Circle().fill(Color.orange).frame(width: 12, height: 12).accessibilityHidden(true)
                Text("This orange dot in the menu bar means the microphone is on.")
                    .font(.system(size: 15))
            }
            .padding(.bottom, 8)
            paragraph("Jarvis listens on your Mac for its name. Nothing leaves your Mac until you say it.")
        case .microphone:
            switch model.microphone {
            case .refused:
                paragraph("Jarvis can't hear you yet. In System Settings, open Privacy & Security, then Microphone, and switch on Jarvis.")
            case .waiting:
                paragraph("Choose Allow in the box that just opened.")
            case .notAsked, .granted:
                paragraph("Jarvis needs the microphone to hear what you ask. What you say is used only to do what you asked.")
            }
        case .accessibility:
            switch model.accessibility {
            case .waiting, .refused:
                paragraph("In System Settings, switch on Jarvis in the Accessibility list. This page moves on by itself when you do.")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to switch it on…").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            case .notAsked, .granted:
                paragraph("To click, type and open apps for you, Jarvis needs Accessibility. macOS will ask you to switch it on in System Settings.")
            }
        case .tryIt:
            if model.triedIt {
                paragraph("You're all set. Say “help” any time to hear what Jarvis can do.")
            } else {
                paragraph(config.handsFreeEnabled
                     ? "Say “Open Calculator”."
                     : "Hold fn and say “Open Calculator”, then let go.")
                if config.handsFreeEnabled {
                    paragraph("Jarvis is listening now. If you'd rather it waited for fn, change that in Settings.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch model.step {
            case .microphone where model.microphone == .refused:
                Button("Check again") { model.refresh() }
                Spacer()
                Button("Open System Settings") { model.allow() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .accessibility where model.accessibility != .notAsked:
                Button("Check again") { model.refresh() }
                Spacer()
                Button("Open System Settings") { Permission.accessibility.openSystemSettings() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .tryIt:
                if !model.triedIt { Button("Skip") { done() } }
                Spacer()
                Button("Done") { done() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .standbyIntro:
                Spacer()
                Button("Continue") { model.advance() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Not now") { model.advance() }
                Spacer()
                Button("Allow") { model.allow() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func done() {
        config.firstRunCompleted = true
        finish()
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

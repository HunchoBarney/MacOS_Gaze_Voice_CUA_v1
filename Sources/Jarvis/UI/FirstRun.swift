import AppKit
import AVFoundation
import SwiftUI

/// The first run: choose how Jarvis listens, allow the microphone, allow
/// Accessibility, then try a command. Each permission step watches the system and moves on by itself
/// once the grant lands, so nobody has to come back and press anything.
@MainActor
final class FirstRunModel: ObservableObject {
    enum Step: CaseIterable {
        /// How Jarvis listens, and what leaves the Mac.
        case listening
        /// Explains the orange microphone dot. Shown only when Standby can
        /// actually run, so it stays hidden until a wake-word engine ships.
        case standbyIntro
        case microphone, accessibility, tryIt
    }

    enum Grant: Equatable { case notAsked, waiting, granted, refused }

    let policy: ListeningPolicy
    let steps: [Step]
    @Published private(set) var step: Step
    /// The listening choice, held until the microphone step has explained
    /// itself: saving Hands-free any earlier would open the mic at once.
    @Published var listeningMode: ListeningMode
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
    /// Saves the listening choice — once, on reaching the try-it step.
    var saveListeningMode: (ListeningMode) -> Void = { _ in }

    init(policy: ListeningPolicy = .current, listeningMode: ListeningMode? = nil) {
        self.policy = policy
        self.listeningMode = listeningMode ?? policy.defaultMode
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
        case .listening, .standbyIntro, .tryIt:
            advance()
        }
    }

    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
        if step == .tryIt { saveListeningMode(listeningMode) }
    }

    func applicationLaunched(bundleID: String?) {
        if step == .tryIt, bundleID == "com.apple.calculator" { triedIt = true }
    }

    nonisolated static func systemMicrophoneGrant() -> Grant {
        if MicrophoneTestGuard.blocksRealMicrophone { return .refused }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .refused
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }
}

struct FirstRunView: View {
    @StateObject private var model: FirstRunModel
    @ObservedObject var config: Config
    var finish: () -> Void

    init(config: Config, finish: @escaping () -> Void) {
        let model = FirstRunModel(listeningMode: config.listeningMode)
        model.saveListeningMode = { config.listeningMode = $0 }
        _model = StateObject(wrappedValue: model)
        self.config = config
        self.finish = finish
    }

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
        .frame(width: 520, height: 440, alignment: .topLeading)
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
        case .listening: return "How should Jarvis listen?"
        case .standbyIntro: return "Jarvis listens for “Hey \(config.assistantName)”"
        case .microphone: return "Let Jarvis hear you"
        case .accessibility: return "Let Jarvis use your Mac"
        case .tryIt: return model.triedIt ? "That worked" : "Try it"
        }
    }

    @ViewBuilder private var content: some View {
        Text(title).font(.system(size: 26, weight: .semibold)).padding(.bottom, 12)
        switch model.step {
        case .listening:
            VStack(spacing: 10) {
                ForEach(model.policy.offeredModes, id: \.self) { mode in
                    ListeningChoice(mode: mode, name: config.assistantName, recommended: mode == model.policy.defaultMode,
                                    selected: model.listeningMode == mode) { model.listeningMode = mode }
                }
            }
            if model.listeningMode == .standby {
                AssistantNameField(config: config).padding(.top, 12)
            }
            Text(model.listeningMode.disclosure(name: config.assistantName))
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        case .standbyIntro:
            HStack(spacing: 10) {
                Circle().fill(Color.orange).frame(width: 12, height: 12).accessibilityHidden(true)
                Text("This orange dot in the menu bar means the microphone is on.")
                    .font(.system(size: 15))
            }
            .padding(.bottom, 8)
            paragraph("Jarvis listens on your Mac for “Hey \(config.assistantName)”. Nothing leaves your Mac until you say it.")
        case .microphone:
            switch model.microphone {
            case .refused:
                paragraph("Jarvis can't hear you yet. In System Settings, open Privacy & Security, then Microphone, and switch on Jarvis.")
            case .waiting:
                paragraph("Choose Allow in the box that just opened.")
            case .notAsked, .granted:
                paragraph("Jarvis needs the microphone to hear what you ask.")
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
            case .listening, .standbyIntro:
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

/// One listening mode as a large, whole-row choice: easier to hit and read
/// than a radio button and its label.
private struct ListeningChoice: View {
    let mode: ListeningMode
    let name: String
    let recommended: Bool
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(mode.title(name: name)).font(.system(size: 16, weight: .semibold))
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(mode.detail).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

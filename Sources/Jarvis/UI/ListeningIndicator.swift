import SwiftUI

/// What the on-screen indicator shows. It drops from the menu bar only
/// while you're talking, while Jarvis is working, when it needs an answer,
/// or when something went wrong that you have to read. Every other state
/// lives in the menu-bar icon and in what Jarvis says.
enum IndicatorPhase: Equatable {
    case hidden, hearing, working, asking, problem

    static func resolve(capture: VoiceController.CaptureState,
                        status: VoiceController.Status,
                        conversationTurnOpen: Bool,
                        activeWork: Bool,
                        pendingAsks: Bool) -> IndicatorPhase {
        switch status {
        case .awaitingConfirm, .reviewTranscript, .awaitingAnswer: return .asking
        default: break
        }
        switch capture {
        case .starting, .listening, .finishing, .awaitingRelease: return .hearing
        case .idle, .testingMicrophone, .stopping: break
        }
        if case .error = status { return .problem }
        if pendingAsks { return .asking }
        if conversationTurnOpen { return .hearing }
        switch status {
        case .thinking, .executing, .stopping: return .working
        default: break
        }
        return activeWork ? .working : .hidden
    }

    @MainActor
    static func current(_ controller: VoiceController) -> IndicatorPhase {
        guard !controller.isMicrophoneTest else { return .hidden }
        return resolve(capture: controller.captureState, status: controller.status,
                       conversationTurnOpen: controller.conversationTurnOpen,
                       activeWork: controller.cuaTasks.contains(where: \.active),
                       pendingAsks: !controller.pendingTaskApprovals.isEmpty
                           || !controller.pendingQuestions.isEmpty)
    }
}

/// The black tab under the notch, plus a card when Jarvis asks something.
/// Words and width change instantly; only the microphone level moves.
struct ListeningIndicatorView: View {
    @ObservedObject var controller: VoiceController
    var openSettings: () -> Void = {}

    private var phase: IndicatorPhase { IndicatorPhase.current(controller) }

    private var activeWork: VoiceTaskCoordinator.Work? {
        controller.cuaTasks.last(where: \.active)
    }

    private var line: String {
        switch phase {
        case .hearing:
            return controller.transcript.isEmpty ? "Listening" : controller.transcript
        case .working:
            let label = activeWork?.label ?? controller.detail
            return (label.isEmpty ? "Working" : label) + "…"
        case .asking:
            return controller.status == .reviewTranscript ? "Is this right?" : "Which one?"
        case .problem:
            return "Something went wrong"
        case .hidden:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            tab
            if phase == .asking { AskCard(controller: controller) }
            if phase == .problem { ProblemCard(controller: controller, openSettings: openSettings) }
        }
        .fixedSize()
        .colorScheme(.dark)
    }

    private var tab: some View {
        HStack(spacing: 9) {
            switch phase {
            case .hearing:
                LevelMeter(level: controller.audioLevel)
            case .working:
                Image(systemName: "ellipsis").foregroundStyle(Color(red: 0.48, green: 0.64, blue: 1))
            case .asking:
                Image(systemName: "questionmark.circle").foregroundStyle(Color(red: 0.73, green: 0.61, blue: 1))
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            case .hidden:
                EmptyView()
            }
            Text(line)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(controller.partialLive ? 0.75 : 1))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 440, alignment: .leading)
            if controller.config.gazeTracking {
                Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    .accessibilityLabel("Eye tracking on")
            }
            if phase == .working {
                Button(action: controller.stopAll) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Stop")
                .help("Stop (Escape)")
            }
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 150, minHeight: 34)
        .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jarvis: \(line)")
    }
}

/// What went wrong, in the words Jarvis said, with a way to fix it when
/// the fix is a permission.
private struct ProblemCard: View {
    @ObservedObject var controller: VoiceController
    var openSettings: () -> Void

    private var message: String {
        if case .error(let text) = controller.status { return text }
        return controller.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.system(size: 15)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.detail.isEmpty, controller.detail != message {
                Text(OutcomeWording.readable(controller.detail)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !controller.missingPermissions.isEmpty {
                    Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
                }
                Button("Dismiss", action: controller.cancelCaptureAttempt).keyboardShortcut(.cancelAction)
                Spacer()
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}

/// The question card under the tab: what Jarvis needs, and buttons that do
/// the same thing as saying the answer.
private struct AskCard: View {
    @ObservedObject var controller: VoiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.status {
            case .reviewTranscript:
                prompt(controller.transcript)
                buttons(primary: ("Continue", controller.acceptTranscript), secondary: ("Cancel", controller.cancel))
            case .awaitingConfirm:
                prompt(controller.transcript)
                buttons(primary: ("Go ahead", controller.confirm), secondary: ("Cancel", controller.cancel))
            case .awaitingAnswer(let question):
                prompt(question)
                buttons(primary: nil, secondary: ("Cancel", controller.cancel))
            default:
                if let task = controller.pendingTaskApproval {
                    prompt(task.askPrompt ?? task.request)
                    buttons(primary: ("Go ahead", { controller.approveTask(task.id, approved: true) }),
                            secondary: ("Cancel", { controller.approveTask(task.id, approved: false) }))
                } else if let question = controller.pendingQuestions.last {
                    prompt(question.prompt)
                }
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func prompt(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(primary: (String, () -> Void)?, secondary: (String, () -> Void)) -> some View {
        HStack {
            if let primary {
                Button(primary.0, action: primary.1).buttonStyle(.borderedProminent)
            }
            Button(secondary.0, action: secondary.1).keyboardShortcut(.cancelAction)
            Spacer()
        }
        .controlSize(.large)
    }
}

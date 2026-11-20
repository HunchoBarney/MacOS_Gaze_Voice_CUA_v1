import AVFoundation
import SwiftUI

/// "Assistant name": the name in "Hey <name>". A name is saved only once
/// the wake-word engine can hear it; otherwise the field says why and keeps
/// the last good name. Settings adds a Test button.
struct AssistantNameField: View {
    @ObservedObject var config: Config
    var controller: VoiceController?
    @State private var draft = ""
    @State private var problem: String?
    @State private var checking: Task<Void, Never>?
    @State private var speaker = PhraseSpeaker()
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Assistant name").font(.system(size: 14))
                TextField("Jarvis", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .accessibilityLabel("Assistant name")
                    .focused($editing)
                    .onSubmit { check(draft, save: true) }
                if let controller {
                    Button("Test") { controller.testWakeWord(say: speaker.say) }
                        .disabled(problem != nil || AssistantName.cleaned(draft) != config.assistantName || testRunning(controller))
                }
            }
            if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let controller, let result = testResult(controller) {
                Text(result).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = config.assistantName }
        .onChange(of: draft) { check(draft, save: false) }
        .onChange(of: editing) { if !editing { check(draft, save: true) } }
        .onDisappear { check(draft, save: true) }
    }

    /// Checks as the person types; saves on Return or when they leave the
    /// field, so Standby doesn't restart on every keystroke.
    private func check(_ typed: String, save: Bool) {
        checking?.cancel()
        let name = AssistantName.cleaned(typed)
        if let local = AssistantName.problem(with: name) { problem = local; return }
        checking = Task {
            if !save { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached { ListeningPolicy.wakeWord?.problem(with: name) }.value
            guard !Task.isCancelled else { return }
            problem = found
            guard save, found == nil else { return }
            if config.assistantName != name { config.assistantName = name }
            if draft != name { draft = name }
        }
    }

    private func testRunning(_ controller: VoiceController) -> Bool {
        controller.wakeTest == .speaking || controller.wakeTest == .listening
    }

    private func testResult(_ controller: VoiceController) -> String? {
        switch controller.wakeTest {
        case .speaking: return "Listen…"
        case .listening: return "Now you say “Hey \(config.assistantName)”."
        case .heard: return "Heard you."
        case .missed: return "Didn't catch it. Try again a little closer to the microphone."
        case .failed(let reason): return reason
        case nil: return nil
        }
    }
}

/// Says a phrase in the system voice and returns when it's done.
@MainActor
final class PhraseSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    func say(_ text: String) async {
        finished?.resume()
        synthesizer.delegate = self
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(AVSpeechUtterance(string: text))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }
}

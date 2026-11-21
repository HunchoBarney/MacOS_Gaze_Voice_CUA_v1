import SwiftUI

/// A rounded group on the Settings and Activity pages.
struct JarvisCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Five bars that follow the microphone level. Reduce Motion holds them at
/// a fixed height so nothing moves.
struct LevelMeter: View {
    let level: Float
    var color = Color(red: 0.31, green: 0.84, blue: 0.64)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape: [CGFloat] = [0.35, 0.7, 1, 0.6, 0.3]

    var body: some View {
        let amp = reduceMotion ? 0.7 : CGFloat(max(0.15, min(1, level * 1.6)))
        HStack(spacing: 2) {
            ForEach(Self.shape.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: 3, height: 4 + 12 * Self.shape[i] * amp)
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

extension VoiceController.Status {
    /// A short, plain description of the state, for Activity and logs.
    var title: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .finishing: return "Finishing…"
        case .reviewTranscript: return "Check what I heard"
        case .thinking: return "Thinking…"
        case .awaitingConfirm: return "Go ahead?"
        case .executing: return "Working…"
        case .stopping: return "Stopping…"
        case .testingMicrophone: return "Testing the microphone"
        case .done: return "Done"
        case .replied: return "Answered"
        case .stopped: return "Stopped"
        case .awaitingAnswer: return "Waiting for your answer"
        case .error: return "Something went wrong"
        }
    }

    var symbol: String {
        switch self {
        case .idle, .stopped: return "waveform"
        case .starting, .listening, .finishing, .testingMicrophone: return "mic"
        case .thinking, .executing, .stopping: return "ellipsis.circle"
        case .reviewTranscript, .awaitingConfirm, .awaitingAnswer: return "questionmark.circle"
        case .done, .replied: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}

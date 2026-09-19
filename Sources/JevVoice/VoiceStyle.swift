// Selected visual patterns adapted from FluidVoice (GPL-3.0).
// See ThirdParty/FluidVoice/NOTICE.md for pinned sources and license.
import SwiftUI

struct VoiceCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.7), in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct VoiceWaveform: View {
    let level: Float
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<11, id: \.self) { index in
                let distance = abs(CGFloat(index) - 5) / 5
                let peak = max(0.18, 0.96 - distance * 0.78)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 4 + 22 * CGFloat(level) * peak)
            }
        }
        .frame(height: 28)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

extension VoiceController.Status {
    var title: String {
        switch self {
        case .idle: return "Ready when you are"
        case .starting: return "Starting microphone…"
        case .listening: return "Listening"
        case .finishing: return "Finishing…"
        case .thinking: return "Understanding…"
        case .awaitingRelease: return "Release Fn to review"
        case .reviewTranscript: return "Review what I heard"
        case .awaitingConfirm: return "Ready to run"
        case .executing: return "Working…"
        case .stopping: return "Stopping…"
        case .testingMicrophone: return "Testing microphone"
        case .done: return "Finished"
        case .error: return "Something needs attention"
        }
    }
    var symbol: String {
        switch self {
        case .listening, .testingMicrophone: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .reviewTranscript, .awaitingRelease: return "text.bubble"
        case .awaitingConfirm: return "play.circle"
        default: return "waveform"
        }
    }
}

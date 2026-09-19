import SwiftUI
import JevVoiceCore

struct OverlayView: View {
    @ObservedObject var controller: VoiceController
    var openReview: () -> Void
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showText: Bool { !controller.transcript.isEmpty && controller.status != .done }
    private var message: String {
        if case .error(let text) = controller.status { return text }
        if controller.status == .done { return controller.resultMessage }
        return controller.detail
    }
    private var showsActions: Bool {
        controller.status == .reviewTranscript || controller.status == .awaitingConfirm || isError
    }
    private var isError: Bool { if case .error = controller.status { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showText {
                Text(controller.transcript)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if controller.status == .awaitingConfirm {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(controller.decisions.filter { $0.action != .none }.enumerated()), id: \.offset) { index, decision in
                            Text("\(index + 1). \(decision.displaySummary)").font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 110)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
            }
            if showText || !message.isEmpty { Divider().overlay(Color.white.opacity(0.08)) }
            HStack(spacing: 12) {
                if controller.status == .listening {
                    VoiceWaveform(level: controller.audioLevel)
                        .help(controller.inputName)
                } else if [.starting, .finishing, .thinking, .executing, .stopping].contains(controller.status) {
                    ProgressView().controlSize(.small).tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: controller.status.symbol)
                        .foregroundStyle(isError ? Color.orange : Color.mint)
                }
                Text(controller.status.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if controller.status == .listening {
                    Text("fn").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.2)))
                }
                Button(action: openReview) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Expand activity").help("Expand activity and settings")
                if controller.status != .stopping && controller.status != .done {
                    Button(action: controller.cancel) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(controller.status == .executing ? "Stop command" : "Cancel command")
                        .help("Escape to cancel")
                }
            }
            if showsActions {
                HStack(spacing: 10) {
                    if controller.status == .awaitingConfirm {
                        Button("Run", action: controller.confirm).buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    } else if controller.status == .reviewTranscript {
                        Button("Review transcript", action: openReview).buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    } else if isError {
                        Button("Open settings", action: openSettings).buttonStyle(.bordered)
                    }
                    Spacer()
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(width: showText || !message.isEmpty || showsActions ? 380 : 290)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            let shape = RoundedRectangle(cornerRadius: showText || showsActions ? 22 : 26, style: .continuous)
            if reduceTransparency { shape.fill(Color(white: 0.10)) }
            else { shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(0.68))) }
        }
        .overlay(RoundedRectangle(cornerRadius: showText || showsActions ? 22 : 26).stroke(.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .colorScheme(.dark)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: controller.status)
    }
}

struct ActivityView: View {
    @ObservedObject var controller: VoiceController
    @State private var showDiagnostics = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(controller.status.title, systemImage: controller.status.symbol).font(.headline)
                    if case .error(let message) = controller.status {
                        Text(message).foregroundStyle(.orange)
                    } else if !controller.detail.isEmpty { Text(controller.detail).foregroundStyle(.secondary) }
                    if !controller.transcript.isEmpty {
                        Text(controller.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if controller.status == .reviewTranscript {
                        Text("Check the captured text. Continue submits it as your command.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Continue", action: controller.acceptTranscript).buttonStyle(.borderedProminent)
                            Button("Cancel", action: controller.cancel)
                        }
                    }
                    if !controller.decisions.isEmpty {
                        Divider()
                        ForEach(Array(controller.decisions.enumerated()), id: \.offset) { index, decision in
                            Text("\(index + 1). \(decision.displaySummary)").textSelection(.enabled)
                        }
                    }
                    if controller.status == .awaitingConfirm {
                        HStack {
                            Button("Run", action: controller.confirm).buttonStyle(.borderedProminent)
                            Button("Cancel", action: controller.cancel)
                        }
                    } else if controller.status == .executing || controller.status == .thinking {
                        Button("Stop", action: controller.cancel)
                    }
                    if controller.status == .done { Text(controller.resultMessage).foregroundStyle(.secondary) }
                    if controller.status == .idle && controller.transcript.isEmpty {
                        Text("Hold Fn anywhere to give your Mac a command. Your recent activity will appear here.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !controller.history.isEmpty {
                Text("RECENT DECISIONS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                VoiceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(controller.history.enumerated()), id: \.offset) { index, decision in
                            if index > 0 { Divider() }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(decision.displaySummary).font(.system(size: 13, weight: .medium))
                                Text(decision.clause).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    if !controller.model.isEmpty { Text("Model: \(controller.model)") }
                    ForEach(controller.measurements.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(Int(controller.measurements[key] ?? 0)) ms")
                    }
                    ForEach(Array(controller.decisions.enumerated()), id: \.offset) { _, decision in
                        Text("\(decision.action.rawValue): \(Int(decision.confidence * 100))% confidence")
                        if let explanation = decision.planExplanation { Text(explanation) }
                    }
                    Text("Dispatch results reflect OS/API responses, not independent verification inside every app.")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.callout)
        }
    }
}

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
        if case .awaitingAnswer(let prompt) = controller.status { return prompt }
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
                if controller.cuaTasks.contains(where: \.active) {
                    Button("Stop All", action: controller.stopAll).buttonStyle(.plain).font(.system(size: 11))
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
            if let task = controller.pendingTaskApproval, let operation = task.approval {
                Text(operation).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Confirm operation") { controller.approveTask(task.id, approved: true) }.buttonStyle(.borderedProminent)
                    Button("Cancel operation") { controller.approveTask(task.id, approved: false) }
                }.controlSize(.small)
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

struct CuaTasksView: View {
    @ObservedObject var controller: VoiceController
    var body: some View {
        if !controller.cuaTasks.isEmpty || !controller.pendingQuestions.isEmpty {
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Cua tasks").font(.headline); Spacer(); Button("Stop All", action: controller.stopAll) }
                    ForEach(controller.cuaTasks) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button(task.label) { controller.selectTask(task.id) }.buttonStyle(.plain)
                                Text(task.status).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if task.approval != nil { Button("Confirm operation") { controller.approveTask(task.id, approved: true) } }
                                if task.active { Button("Stop") { controller.cancelTask(task.id) } }
                                if controller.canRetryTask(task.id) {
                                    Button("Retry") { controller.retryTask(task.id) }
                                        .help("Ask to run this request again; Jev re-checks the current state first")
                                }
                            }
                            Text(task.request).font(.callout)
                            Text(task.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(controller.taskDiagnostics(task), id: \.self) {
                                Text($0).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    ForEach(controller.pendingQuestions) { question in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(question.prompt, systemImage: "questionmark.bubble").font(.callout)
                            Text("awaiting answer · for: \(question.owner)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

struct ActivityView: View {
    @ObservedObject var controller: VoiceController
    @EnvironmentObject private var agentsModel: AgentsViewModel
    @Environment(\.openAgents) private var openAgents
    @State private var showDiagnostics = false
    @State private var commandText = ""

    private var trimmedCommand: String {
        commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canRunCommand: Bool {
        !trimmedCommand.isEmpty && controller.canSubmitCommand
    }

    private func runCommand() {
        controller.submitTypedCommand(commandText)
        commandText = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VoiceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Type a command", systemImage: "keyboard").font(.headline)
                    HStack {
                        TextField("e.g. open Calculator", text: $commandText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(runCommand)
                        Button("Run", action: runCommand)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canRunCommand)
                    }
                    Text("Runs through the same Cua path as a spoken command — same targeting, verification, and confirmation rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VoiceCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Decision feed", systemImage: "list.bullet.rectangle").font(.headline)
                    if controller.cua.feed.entries.isEmpty {
                        Text("Nothing yet — hold Fn and speak; each routing decision, dispatch, and verification lands here as it happens.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.cua.feed.entries.suffix(30).reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.kind.symbol)
                                    .font(.system(size: 10)).frame(width: 14)
                                    .foregroundStyle(entry.kind == .error ? Color.orange
                                        : entry.kind == .consent ? Color.yellow
                                        : entry.kind == .verify ? Color.mint
                                        : Color.secondary)
                                Text(entry.text).font(.caption).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.at, style: .time).font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            CuaTasksView(controller: controller)
            VoiceCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Agents", systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button("Open agents", action: openAgents).controlSize(.small)
                    }
                    if agentsModel.agents.isEmpty {
                        Text("No agents yet — ask Jev for a recurring job and a helper appears here.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(agentsModel.agents) { agent in
                            HStack(spacing: 8) {
                                Circle().fill(Color(agentHex: AgentCursor.palette(for: agent.slug)))
                                    .frame(width: 7, height: 7)
                                Text(agent.name).font(.callout)
                                Text(agentsModel.chat(for: agent.slug).busy ? "Working…" : agent.role)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
                .task { await agentsModel.refresh() }
            }
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
                    if controller.status == .awaitingConfirm {
                        HStack {
                            Button("Run", action: controller.confirm).buttonStyle(.borderedProminent)
                            Button("Cancel", action: controller.cancel)
                        }
                    } else if controller.status == .executing || controller.status == .thinking {
                        Button("Stop", action: controller.cancel)
                    } else if case .awaitingAnswer = controller.status {
                        Button("Dismiss", action: controller.cancel)
                    }
                    if controller.status == .done { Text(controller.resultMessage).foregroundStyle(.secondary) }
                    if controller.status == .idle && controller.transcript.isEmpty {
                        Text("Hold Fn anywhere to give your Mac a command. Your recent activity will appear here.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Latest voice capture").fontWeight(.medium)
                    ForEach(controller.measurements.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(Int(controller.measurements[key] ?? 0)) ms")
                    }
                    if let task = controller.diagnosticTask {
                        Text("Selected task: \(task.label)").fontWeight(.medium)
                        ForEach(controller.taskDiagnostics(task), id: \.self) { Text($0) }
                        Text("Task elapsed: \(Int(task.elapsedMs)) ms")
                        ForEach(task.timings.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(Int(task.timings[key] ?? 0)) ms")
                        }
                    }
                    Text("Dispatch results reflect OS/API responses, not independent verification inside every app.")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.callout)
        }
    }
}

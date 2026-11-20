import SwiftUI
import JarvisCore

struct CuaTasksView: View {
    @ObservedObject var controller: VoiceController
    var body: some View {
        if !controller.cuaTasks.isEmpty || !controller.pendingQuestions.isEmpty {
            JarvisCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("What Jarvis is doing").font(.headline); Spacer(); Button("Stop everything", action: controller.stopAll) }
                    ForEach(controller.cuaTasks) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button(task.label) { controller.selectTask(task.id) }.buttonStyle(.plain)
                                Text(task.statusText).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if task.awaitingApproval { Button("Go ahead") { controller.approveTask(task.id, approved: true) } }
                                if task.active { Button("Stop") { controller.cancelTask(task.id) } }
                                if controller.canRetryTask(task.id) {
                                    Button("Retry") { controller.retryTask(task.id) }
                                        .help("Ask to run this request again; Jarvis re-checks the current state first")
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
            JarvisCard {
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
                    Text("Works just like saying it out loud.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            JarvisCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("What happened", systemImage: "list.bullet.rectangle").font(.headline)
                    if controller.cua.feed.entries.isEmpty {
                        Text("Nothing yet. Ask Jarvis something and each step shows up here.")
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
            JarvisCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Agents", systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button("Open agents", action: openAgents).controlSize(.small)
                    }
                    if agentsModel.agents.isEmpty {
                        Text("No agents yet — ask Jarvis for a recurring job and a helper appears here.")
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
            JarvisCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(controller.handsFreeEnabled ? controller.handsFreeLabel : controller.status.title,
                          systemImage: controller.status.symbol).font(.headline)
                    if case .error(let message) = controller.status {
                        Text(message).foregroundStyle(.orange)
                    } else if !controller.detail.isEmpty { Text(controller.detail).foregroundStyle(.secondary) }
                    if !controller.transcript.isEmpty {
                        Text(controller.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if controller.status == .reviewTranscript {
                        Text("Check what Jarvis heard. Continue does it.")
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
                        Text("Speak, or hold Fn, to give your Mac a command. Your recent activity will appear here.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

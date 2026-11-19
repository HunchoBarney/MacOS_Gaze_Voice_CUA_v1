import AppKit
import SwiftUI

struct AgentChatView: View {
    @ObservedObject var model: AgentsViewModel
    let agent: CompanionAgent
    /// Typing lives in @State — publishing every keystroke through
    /// `model.drafts` re-renders the whole roster and chat per character.
    /// `model.drafts` still carries drafts across agent switches/closes.
    @State private var draft = ""

    private var chat: AgentChat { model.chat(for: agent.slug) }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(Color(agentHex: AgentCursor.palette(for: agent.slug)))
                        .frame(width: 10, height: 10)
                    Text(agent.name).font(.system(size: 17, weight: .semibold))
                    Text(agent.role).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if chat.busy {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.interrupt(slug: agent.slug) }.controlSize(.small)
                    }
                }
                Text("Founded \(agent.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(agent.workspacePath)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            if !agent.routines.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(agent.routines) { routine in
                            Label("\(routine.scheduleLabel) · \(routine.task)",
                                  systemImage: routine.enabled ? "repeat" : "pause.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(routine.enabled ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .help(routine.enabled ? "Runs while Jarvis is open" : "Paused")
                        }
                    }.padding(.horizontal, 18)
                }.padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            Text("No messages yet — say what you need and \(agent.name) picks it up.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                        ForEach(chat.messages) { message in
                            messageRow(message)
                        }
                        if let activity = chat.activity, chat.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(activity).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("chatBottom")
                }
                .onChange(of: chat.messages.count) { proxy.scrollTo("chatBottom") }
                .onChange(of: chat.messages.last?.text) { proxy.scrollTo("chatBottom") }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Message \(agent.name)…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).buttonStyle(.borderedProminent).disabled(!canSend)
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { draft = model.drafts[agent.slug] ?? "" }
        .onChange(of: agent.slug) { previous, next in
            model.drafts[previous] = draft
            draft = model.drafts[next] ?? ""
        }
        .onDisappear { model.drafts[agent.slug] = draft }
    }

    private func send() {
        model.send(draft, to: agent.slug)
        draft = ""
    }

    @ViewBuilder
    private func messageRow(_ message: AgentChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .note:
            Text(message.text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .agent:
            VStack(alignment: .leading, spacing: 6) {
                Text(AgentFinalMessage.stripMarkers(message.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.streaming {
                    Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let final = message.final, final.hasStructuredBlocks {
                    finalBlock(final)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func finalBlock(_ final: AgentFinalMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title = final.doneTitle {
                Label(title, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.mint)
            }
            if let summary = final.summary {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !final.nextActions.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(final.nextActions, id: \.self) { action in
                        Button(action) { model.send(action, to: agent.slug) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.mint.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(Color.mint.opacity(0.35)))
                    }
                }
            }
            ForEach(final.artifacts, id: \.self) { artifact in
                Button { open(artifact) } label: {
                    Label(artifactName(artifact), systemImage: "doc")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                .buttonStyle(.link)
                .help(artifact)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    private func artifactName(_ artifact: String) -> String {
        if let url = URL(string: artifact), let host = url.host, url.scheme?.hasPrefix("http") == true {
            return "\(host)\(url.path)"
        }
        return URL(fileURLWithPath: artifact).lastPathComponent
    }

    private func open(_ artifact: String) {
        if let url = URL(string: artifact), url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact)])
        }
    }
}

/// Wraps chips onto rows — a horizontal flow of fixed-content children.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

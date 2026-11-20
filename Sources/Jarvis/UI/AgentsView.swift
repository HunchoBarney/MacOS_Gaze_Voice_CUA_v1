import SwiftUI

private enum OpenAgentsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Injected by AppWindows so any card can open the agents window.
    var openAgents: () -> Void {
        get { self[OpenAgentsKey.self] }
        set { self[OpenAgentsKey.self] = newValue }
    }
}

extension Color {
    /// "#rrggbb" / "#rgb" palette hex (AgentCursor.colorHex).
    init(agentHex: String) {
        var hex = agentHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

struct AgentsView: View {
    @ObservedObject var model: AgentsViewModel

    private var selected: CompanionAgent? {
        model.agents.first { $0.slug == model.selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold)).foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agents").font(.system(size: 15, weight: .semibold))
                        Text("Persistent helpers").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 18)
                if model.agents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No agents yet").font(.system(size: 13, weight: .medium))
                        Text("Ask Jarvis for a recurring job and a helper appears here.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(model.agents) { agent in
                                rosterRow(agent)
                            }
                        }
                    }
                }
                Spacer()
            }.padding(.horizontal, 14).frame(width: 200).background(.ultraThinMaterial)
            Divider()
            if let agent = selected {
                AgentChatView(model: model, agent: agent)
            } else {
                Text(model.agents.isEmpty ? "Agents Jarvis creates for you appear here." : "Select an agent.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.refresh()
            }
        }
    }

    private func rosterRow(_ agent: CompanionAgent) -> some View {
        Button { model.selection = agent.slug } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(agentHex: AgentCursor.palette(for: agent.slug)))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(model.chat(for: agent.slug).busy ? "Working…" : agent.role)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !agent.routines.isEmpty {
                    Image(systemName: "repeat").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(model.selection == agent.slug ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Files this helper creates live in its own private workspace.")
    }
}

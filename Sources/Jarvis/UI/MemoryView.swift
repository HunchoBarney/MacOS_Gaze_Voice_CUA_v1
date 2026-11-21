import SwiftUI
import GRDB

/// Settings → Memory: the live list of what Jarvis remembers, kept in step
/// with the database so a memory added by voice shows up at once.
@MainActor
final class MemoryModel: ObservableObject {
    @Published private(set) var memories: [Memory] = []
    @Published private(set) var problem: String?
    private let store: MemoryStore
    private var observation: AnyDatabaseCancellable?

    init(store: MemoryStore) {
        self.store = store
        start()
    }

    private func start() {
        guard observation == nil else { return }
        do {
            observation = try store.observeAll(
                onError: { [weak self] _ in self?.problem = "Jarvis couldn't read its memory." },
                onChange: { [weak self] in self?.memories = $0; self?.problem = nil })
        } catch {
            problem = "Jarvis couldn't open its memory."
        }
    }

    func delete(_ memory: Memory) {
        guard let id = memory.id else { return }
        do { try store.delete([id]) } catch { problem = "Jarvis couldn't forget that. Try again." }
    }

    func forgetAll() {
        do { try store.forgetAll() } catch { problem = "Jarvis couldn't forget everything. Try again." }
    }
}

struct MemoryView: View {
    @StateObject private var model: MemoryModel
    @State private var query = ""
    @State private var confirmingForgetAll = false

    init(store: MemoryStore) {
        _model = StateObject(wrappedValue: MemoryModel(store: store))
    }

    private struct Group: Identifiable {
        let kind: Memory.Kind
        let title: String
        let symbol: String
        var id: Memory.Kind { kind }
    }

    private static let groups = [
        Group(kind: .person, title: "People", symbol: "person.2"),
        Group(kind: .preference, title: "Preferences", symbol: "slider.horizontal.3"),
        Group(kind: .note, title: "Things you asked Jarvis to remember", symbol: "bookmark"),
        Group(kind: .request, title: "Past requests", symbol: "clock.arrow.circlepath"),
    ]

    private var shown: [Memory] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.memories }
        return model.memories.filter {
            $0.text.localizedStandardContains(needle) || ($0.subject?.localizedStandardContains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            JarvisCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("What Jarvis remembers", systemImage: "brain.head.profile")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !model.memories.isEmpty {
                        TextField("Search memories", text: $query)
                            .textFieldStyle(.roundedBorder)
                    }
                    content
                }
            }
            JarvisCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Forget everything", systemImage: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    caption("Deletes every memory from this Mac. Past requests are forgotten on their own after 90 days.")
                    Button("Forget Everything…", role: .destructive) { confirmingForgetAll = true }
                        .disabled(model.memories.isEmpty)
                        .confirmationDialog("Forget everything Jarvis remembers?",
                                            isPresented: $confirmingForgetAll) {
                            Button("Forget Everything", role: .destructive) { model.forgetAll() }
                        } message: {
                            Text("This deletes all of it from this Mac and can't be undone.")
                        }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let visible = shown
        if let problem = model.problem {
            caption(problem, tint: .orange)
        } else if model.memories.isEmpty {
            caption("Nothing yet. Say “Remember Dana is my manager” and it shows up here.")
        } else if visible.isEmpty {
            caption("Nothing matches “\(query)”.")
        } else {
            ForEach(Self.groups) { group in
                let rows = visible.filter { $0.kind == group.kind }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(group.title, systemImage: group.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer(minLength: 8)
                            Text(rows.count, format: .number).monospacedDigit()
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .accessibilityLabel("\(rows.count) in \(group.title)")
                        }
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(rows) { memory in
                                MemoryRow(memory: memory) { model.delete(memory) }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func caption(_ text: String, tint: Color = .secondary) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MemoryRow: View {
    let memory: Memory
    let onDelete: () -> Void

    private var detail: String {
        if let expires = memory.expiresAt {
            return "Kept until \(expires.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Remembered \(memory.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.text).font(.system(size: 14))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget this")
            .accessibilityLabel("Forget “\(memory.text)”")
        }
        .accessibilityElement(children: .contain)
    }
}

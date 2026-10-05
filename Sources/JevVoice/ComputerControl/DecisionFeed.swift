import Foundation

/// The live decision feed: a bounded, chronological record of what Jev heard,
/// how it was routed, what was dispatched, and what was verified. Written by
/// the voice runtime at real transition points — never speculatively — so the
/// feed only ever shows things that actually happened.
@MainActor
final class DecisionFeed: ObservableObject {
    enum Kind: String {
        case heard, route, dispatch, verify, consent, outcome, note, error
        var symbol: String {
            switch self {
            case .heard: return "quote.bubble"
            case .route: return "arrow.triangle.branch"
            case .dispatch: return "paperplane"
            case .verify: return "checkmark.shield"
            case .consent: return "hand.raised"
            case .outcome: return "flag.checkered"
            case .note: return "text.bubble"
            case .error: return "exclamationmark.triangle"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let kind: Kind
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    private let limit = 200

    func add(_ kind: Kind, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The same transition can surface twice through nested reporting —
        // collapse only an exact back-to-back duplicate, never history.
        if entries.last?.kind == kind, entries.last?.text == trimmed { return }
        entries.append(Entry(at: Date(), kind: kind, text: trimmed))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}

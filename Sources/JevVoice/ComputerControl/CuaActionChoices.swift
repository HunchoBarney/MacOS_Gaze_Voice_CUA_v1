import Foundation

struct CuaActionOwner: Equatable {
    let taskID: UUID
    let revision: Int
}

struct CuaActionCandidate {
    let id: String
    let owner: CuaActionOwner
    let action: CuaObservedAction
}

struct CuaActionChoicePage {
    enum Mode: Equatable {
        case actions
        case targetGroups
    }

    let mode: Mode
    let choices: [String: String?]
    let candidateIDs: Set<String>
    let groupIDs: Set<String>
    let page: Int
    let pageCount: Int
}

/// Holds immutable Cua arguments outside Jev's answer. Dense snapshots first
/// expose target groups, then the selected target's actions. Pagination leaves
/// every candidate reachable while keeping each Choice within Jev's 255 limit.
struct CuaActionChoiceBook {
    static let maxChoices = 255
    static let nextPageID = "__more_actions__"
    static let previousPageID = "__previous_actions__"
    static let backToTargetsID = "__back_to_targets__"

    private struct TargetGroup {
        let id: String
        let description: String
        let candidates: [CuaActionCandidate]
    }

    private let candidates: [CuaActionCandidate]
    private let groups: [TargetGroup]
    private let candidatesByID: [String: CuaActionCandidate]
    private let groupsByID: [String: TargetGroup]

    var candidateCount: Int { candidates.count }

    init(actions: [CuaObservedAction], owner: CuaActionOwner) {
        var candidates: [CuaActionCandidate] = []
        var grouped: [String: [CuaActionCandidate]] = [:]
        var groupOrder: [String] = []

        for (index, action) in actions.enumerated() {
            let candidate = CuaActionCandidate(id: "candidate_\(UUID().uuidString)", owner: owner, action: action)
            candidates.append(candidate)
            let key = action.targetIdentity ?? "unresolved-target:\(index)"
            if grouped[key] == nil { groupOrder.append(key); grouped[key] = [] }
            grouped[key, default: []].append(candidate)
        }

        let groups = groupOrder.compactMap { key -> TargetGroup? in
            guard let members = grouped[key], !members.isEmpty else { return nil }
            let first = members[0].action
            return TargetGroup(id: "target_\(UUID().uuidString)",
                               description: "Target group: \(first.description) (\(members.count) available action\(members.count == 1 ? "" : "s"))",
                               candidates: members)
        }
        self.candidates = candidates
        self.groups = groups
        self.candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        self.groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    }

    func rootPage(reservedChoices: [String: String?], page: Int) -> CuaActionChoicePage {
        if candidates.count + reservedChoices.count <= Self.maxChoices {
            return Self.makePage(mode: .actions, items: candidates.map { ($0.id, $0.action.description) },
                                 reserved: reservedChoices, page: page, paginate: false)
        }
        return Self.makePage(mode: .targetGroups, items: groups.map { ($0.id, $0.description) },
                             reserved: reservedChoices, page: page, paginate: true)
    }

    func actionPage(groupID: String, reservedChoices: [String: String?], page: Int) -> CuaActionChoicePage {
        guard let group = groupsByID[groupID] else {
            return CuaActionChoicePage(mode: .actions, choices: reservedChoices, candidateIDs: [], groupIDs: [], page: 0, pageCount: 1)
        }
        return Self.makePage(mode: .actions, items: group.candidates.map { ($0.id, $0.action.description) },
                             reserved: reservedChoices, page: page, paginate: true)
    }

    func candidate(id: String, owner: CuaActionOwner) -> CuaActionCandidate? {
        guard let candidate = candidatesByID[id], candidate.owner == owner else { return nil }
        return candidate
    }

    func isTargetGroup(_ id: String) -> Bool { groupsByID[id] != nil }

    private static func makePage(mode: CuaActionChoicePage.Mode,
                                 items: [(String, String)],
                                 reserved: [String: String?],
                                 page requestedPage: Int,
                                 paginate: Bool) -> CuaActionChoicePage {
        guard reserved.count < maxChoices else {
            return CuaActionChoicePage(mode: mode, choices: [:], candidateIDs: [], groupIDs: [], page: 0, pageCount: 1)
        }
        let pageSize = max(1, maxChoices - reserved.count - 2)
        let pageCount = paginate ? max(1, (items.count + pageSize - 1) / pageSize) : 1
        let page = min(max(0, requestedPage), pageCount - 1)
        let start = paginate ? page * pageSize : 0
        let end = paginate ? min(items.count, start + pageSize) : items.count
        var choices = reserved
        var candidateIDs = Set<String>()
        var groupIDs = Set<String>()
        for (id, description) in items[start..<end] {
            choices[id] = description
            if id.hasPrefix("candidate_") { candidateIDs.insert(id) }
            if id.hasPrefix("target_") { groupIDs.insert(id) }
        }
        if page > 0 { choices[previousPageID] = "Show the previous page of choices." }
        if page + 1 < pageCount { choices[nextPageID] = "Show the next page of choices." }
        return CuaActionChoicePage(mode: mode, choices: choices, candidateIDs: candidateIDs,
                                   groupIDs: groupIDs, page: page, pageCount: pageCount)
    }
}

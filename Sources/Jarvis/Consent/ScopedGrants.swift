import Foundation
import JarvisCore
import os

/// Scoped "Always for this app" grants — the third consent shape between
/// the per-dispatch ask and the blanket standing grant.
///
/// A consent ask that gets answered "always" for a `(actionKind,
/// appBundleID)` pair persists a row in `policy.json`, right next to the
/// standing grant the same file already carries:
///
/// ```json
/// { "standingGrant": false, "version": 2,
///   "scopedGrants": [ {"action": "click", "bundle": "com.apple.Safari"} ] }
/// ```
///
/// Scope is the whole point: a grant for `click` in Safari authorizes
/// nothing else and nowhere else — matching is exact on the normalized
/// pair, no wildcards, no leakage. Agent MCP children read the same file
/// the app writes, so a scoped grant answers their `consentGate` too.
///
/// Caller wiring (coordinator lane): when a consent ask resolves
/// "always", call `grantAlways(actionKind: tool, appBundleID: bundle)`
/// with the dispatch's tool name and resolved target bundle. Then either
/// pass `scopedGrant:` into `decide`, or fold it into the grant closure:
/// `granted: { standingGrant() || CuaPolicy.scopedGrantAllows(actionKind: tool, appBundleID: bundle) }`.
extension CuaPolicy {

    /// One persisted scope pair — the driver action (`"click"`,
    /// `"type_text"`, …) and the app it may run in.
    struct ScopedGrant: Sendable, Equatable {
        var actionKind: String
        var appBundleID: String
    }

    /// Persist an "Always for this app" answer — dedupes on the
    /// normalized pair and preserves the file's standing grant.
    static func grantAlways(actionKind: String, appBundleID: String) {
        let state = readPolicyState()
        let wanted = normalizeScope(actionKind, appBundleID)
        guard !state.scopedGrants.contains(where: {
            normalizeScope($0.actionKind, $0.appBundleID) == wanted
        }) else { return }
        writePolicyFile(standingGrant: state.standingGrant,
                        scopedGrants: state.scopedGrants
                            + [ScopedGrant(actionKind: actionKind,
                                           appBundleID: appBundleID)])
    }

    /// Drop one scoped grant — the next dispatch for that pair asks again.
    static func revokeAlways(actionKind: String, appBundleID: String) {
        let state = readPolicyState()
        let wanted = normalizeScope(actionKind, appBundleID)
        let kept = state.scopedGrants.filter {
            normalizeScope($0.actionKind, $0.appBundleID) != wanted
        }
        guard kept.count != state.scopedGrants.count else { return }
        writePolicyFile(standingGrant: state.standingGrant, scopedGrants: kept)
    }

    /// Every persisted scope pair — for a settings surface to list.
    static func scopedGrants() -> [ScopedGrant] {
        readPolicyState().scopedGrants
    }

    /// The read side the dispatch gates call: is there a persisted
    /// "always" for exactly this action in exactly this app? Matching is
    /// the normalized pair — a Safari click grant never answers for Mail.
    static func scopedGrantAllows(actionKind: String, appBundleID: String) -> Bool {
        let wanted = normalizeScope(actionKind, appBundleID)
        return readPolicyState().scopedGrants.contains {
            normalizeScope($0.actionKind, $0.appBundleID) == wanted
        }
    }

    private static func normalizeScope(_ action: String, _ bundle: String)
        -> (action: String, bundle: String) {
        (action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
         bundle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    // MARK: - policy.json read/write (shared with publishStateFile)

    /// The decoded consent file — missing or malformed reads as "no
    /// grant, no scopes", the same fail-closed posture the children use.
    static func readPolicyState() -> (standingGrant: Bool, scopedGrants: [ScopedGrant]) {
        guard let data = try? Data(contentsOf: policyFile),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return (false, []) }
        let grants = (object["scopedGrants"]?.array ?? []).compactMap { row -> ScopedGrant? in
            guard let action = row["action"]?.string,
                  let bundle = row["bundle"]?.string else { return nil }
            return ScopedGrant(actionKind: action, appBundleID: bundle)
        }
        return (object["standingGrant"]?.bool ?? false, grants)
    }

    /// The single writer every consent mutation goes through. Removal
    /// precedes the write so a failed write can never leave a stale
    /// `true` behind — a missing file reads as "no grant". An off-state
    /// with no scoped grants removes the file outright; an off-state
    /// WITH scoped grants stays on disk with `standingGrant: false`
    /// spelled out, still an honest off.
    static func writePolicyFile(standingGrant: Bool, scopedGrants: [ScopedGrant]) {
        let fm = FileManager.default
        let dir = policyFile.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: policyFile.path) {
                try fm.removeItem(at: policyFile)
            }
        } catch {
            log.error("policy file delete failed: \(error.localizedDescription)")
        }
        guard standingGrant || !scopedGrants.isEmpty else { return }
        let body = JSONValue.object([
            "standingGrant": .bool(standingGrant),
            "version": .number(2),
            "scopedGrants": .array(scopedGrants.map {
                .object(["action": .string($0.actionKind),
                         "bundle": .string($0.appBundleID)])
            }),
        ])
        do {
            try JSONEncoder().encode(body).write(to: policyFile, options: [.atomic])
        } catch {
            log.error("policy file write failed: \(error.localizedDescription)")
        }
    }
}

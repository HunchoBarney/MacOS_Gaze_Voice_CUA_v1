import Foundation
import JevVoiceCore

/// Candidate adapter for the pinned Driver's deterministic verification contract.
/// A satisfied predicate proves only that predicate, never the whole task.
/// Kept out of the production loop until native/browser replacement proofs pass.
enum CuaStateVerification {
    enum Outcome: Equatable {
        case satisfied
        case unsatisfied
        case unknown
    }

    @MainActor
    static func elementValue(pid: Int, window: Int, role: String, label: String? = nil,
                             value: String, call: CuaTaskAgent.Call) async throws -> Outcome {
        guard pid > 0, window > 0, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
            throw DriverConnectionError.malformed
        }
        var selector: [String: JSONValue] = ["role": .string(role)]
        if let label { selector["label_contains"] = .string(label) }
        try Task.checkCancellation()
        let result = try await call("verify_state", [
            "pid": .number(Double(pid)), "window_id": .number(Double(window)),
            "expect": .array([.object(["element": .object([
                "selector": .object(selector), "exists": .bool(true), "value_equals": .string(value)
            ])])]),
            "timeout_ms": .number(1000), "stable_samples": .number(2),
            "include_screenshot": .bool(false)
        ])
        try Task.checkCancellation()
        return try outcome(result)
    }

    static func outcome(_ result: JSONValue) throws -> Outcome {
        guard let status = result["status"]?.string,
              let stable = result["stable"]?.bool,
              let samples = result["samples"]?.integer, samples > 0,
              let predicates = result["predicates"]?.array, predicates.count == 1,
              predicates[0]["index"] == .number(0),
              let predicateStatus = predicates[0]["status"]?.string,
              ["satisfied", "unsatisfied", "unknown"].contains(status),
              predicateStatus == status else { throw DriverConnectionError.malformed }
        switch status {
        case "satisfied":
            guard stable, samples >= 2, predicates[0]["unknown_reason"] == .null else {
                throw DriverConnectionError.malformed
            }
            return .satisfied
        case "unsatisfied": return .unsatisfied
        default: return .unknown
        }
    }
}

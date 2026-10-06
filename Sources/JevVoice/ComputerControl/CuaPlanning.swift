import Foundation

/// What the planner hands back — advisory only. `steps` sketch the route;
/// `successContains` are literal strings that must be observable on screen
/// when the goal is truly done (they fold into DriveTask.successContains,
/// so they still gate on the observed corpus — a plan can never claim
/// success itself).
struct DrivePlan: Sendable, Equatable {
    struct Hints: Sendable, Equatable {
        var preferVisual = false
        var notes: String?
        init(preferVisual: Bool = false, notes: String? = nil) {
            self.preferVisual = preferVisual; self.notes = notes
        }
    }
    var steps: [String] = []
    var successContains: [String] = []
    var hints = Hints()
    init(steps: [String] = [], successContains: [String] = [], hints: Hints = Hints()) {
        self.steps = steps; self.successContains = successContains; self.hints = hints
    }
}

/// The planner seam — an injected stub (tests) or the one-shot
/// `CuaLitePlanner`. The contract is one optional plan; nil always means
/// "run the plain loop".
protocol CuaPlanning: Sendable {
    func plan(goal: String, appName: String?, windowTitle: String?,
              previousContext: String?) async -> DrivePlan?
    /// Stateless planners ignore this; kept for injected stubs.
    func warmUp() async
}

extension CuaPlanning {
    func warmUp() async {}
}

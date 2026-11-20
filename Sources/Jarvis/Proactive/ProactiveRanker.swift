import Foundation

/// Deterministic tier rules: the category sets the tier, the more/less
/// level moves it, and what the person taught with "not now" lowers it.
enum ProactiveRanker {
    static func tier(for alert: ProactiveAlert, level: ProactiveLevel,
                     learning: ProactiveLearning, now: Date) -> ProactiveTier {
        var tier = alert.category.baseTier
        switch level {
        case .quiet:
            if !alert.category.exemptFromBudget { tier = tier == .speakNow ? .glow : .digest }
        case .normal:
            break
        case .chatty:
            if tier == .glow { tier = .speakNow }
        }
        if tier == .speakNow, alert.category.learns,
           learning.isSnoozed(alert, now: now) || learning.isDemoted(alert.category) {
            tier = .glow
        }
        return tier
    }
}

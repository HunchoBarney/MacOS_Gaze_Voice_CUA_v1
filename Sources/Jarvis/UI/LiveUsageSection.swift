import SwiftUI

/// This month's Live voice in Settings while `voice.live` is on (KAR-75
/// L10). Built from the stock controls Settings already uses; JARA-57
/// restyles it with the rest of Settings.
struct LiveUsageSection: View {
    @ObservedObject var allowance: LiveAllowance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = allowance.status, let used = LiveAllowance.usedLine(status), let fraction = status.fractionUsed {
                HStack {
                    Text(used).font(.system(size: 14))
                    Spacer()
                    Text("Renews \(LiveAllowance.day(status.periodEnds))").font(.callout).foregroundStyle(.secondary)
                }
                ProgressView(value: fraction)
                    .accessibilityLabel("Live voice used this month")
                    .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
                if case .basic(let until) = allowance.mode {
                    Text(LiveAllowance.basicVoiceLine(until: until)).font(.callout).foregroundStyle(.orange)
                } else if fraction >= status.warnAt {
                    Text("Most of this month's Live voice is used. Basic voice takes over when it runs out.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if allowance.status?.metering == false {
                Text("Live voice isn't metered on this Mac.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Checking this month's Live voice…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { await allowance.refresh() }
    }
}

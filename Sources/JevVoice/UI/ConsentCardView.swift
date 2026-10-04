import SwiftUI

/// Inline ask inside an agent's chat — mirrors Clicky's Allow/Not-now card.
/// Pending shows buttons; resolved shows its outcome, including `expired`
/// for asks the gate dropped before anyone answered.
struct ConsentCardView: View {
    let display: ConsentDisplay
    let agentName: String
    var resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(agentName) wants computer input", systemImage: "hand.raised")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            Text(display.request.summary).font(.system(size: 13))
            if !display.request.reason.isEmpty {
                Text(display.request.reason).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                switch display.resolution {
                case .pending:
                    Button("Approve") { resolve(true) }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    Button("Not now") { resolve(false) }.buttonStyle(.bordered)
                case .approved:
                    Label("Approved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                case .denied:
                    Label("Declined", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                case .expired:
                    Label("Expired", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(display.resolution == .pending ? Color.orange.opacity(0.45)
                                                   : Color.primary.opacity(0.08)))
    }
}

import AppKit
import SwiftUI
@testable import Jarvis

// Proposed directions for the audit (reports/JARA-56-ui-audit.md), drawn in
// SwiftUI so they render next to the current views at the same size and on
// the same desktop. Mockups only: nothing here ships. The production build
// would use the libraries the audit names (DynamicNotchKit for the island,
// Orb by metasidd for the voice orb, Wave for the springs).

/// The island grows out of the hardware notch: flush with the top edge,
/// concave flares where it meets the menu bar, continuous bottom corners.
struct IslandShape: Shape {
    var flare: CGFloat = 10
    var bottom: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let f = flare, b = min(bottom, (rect.height - f) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - b))
        p.addCurve(to: CGPoint(x: rect.minX + f + b, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + f, y: rect.maxY - b * 0.35),
                   control2: CGPoint(x: rect.minX + f + b * 0.35, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - b, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - b),
                   control1: CGPoint(x: rect.maxX - f - b * 0.35, y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - f, y: rect.maxY - b * 0.35))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// A stand-in for Orb (metasidd/Orb, MIT): a lit sphere whose size and
/// glow follow the smoothed voice level. Still frames only.
struct VoiceOrb: View {
    var level: CGFloat
    var thinking = false
    var size: CGFloat = 20

    var body: some View {
        let scale = 1 + 0.22 * min(1, level)
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [Color(red: 0.25, green: 0.85, blue: 0.95), Color(red: 0.35, green: 0.45, blue: 1),
                                               Color(red: 0.72, green: 0.42, blue: 1), Color(red: 0.25, green: 0.85, blue: 0.95)],
                                      center: .center, angle: .degrees(thinking ? 140 : 20)))
                .blur(radius: 2.2)
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0)], center: .init(x: 0.36, y: 0.32),
                                     startRadius: 0, endRadius: size * 0.42))
                .blendMode(.plusLighter)
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .shadow(color: Color(red: 0.35, green: 0.6, blue: 1).opacity(0.55 + 0.35 * min(1, level)), radius: 6 + 6 * level)
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

struct IslandFixture {
    enum Mode { case hearing, working, confirm, problem, guide }
    var mode: Mode
    var text = ""
    var detail = ""
    var level: CGFloat = 0.4
    var notch = CGSize(width: 185, height: 32)
}

/// Proposed listening indicator: one black surface that extends the notch,
/// with the orb on the left, words that fade at the leading edge instead of
/// an ellipsis, and the ask growing out of the same surface.
struct IslandProposal: View {
    let fixture: IslandFixture
    private let flare: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: fixture.notch.height - 4)
            header
            if fixture.mode == .confirm || fixture.mode == .problem { card }
        }
        .padding(.horizontal, flare + 14)
        .padding(.bottom, fixture.mode == .confirm || fixture.mode == .problem ? 16 : 10)
        .frame(minWidth: fixture.notch.width + 2 * flare + 120, alignment: .leading)
        .fixedSize()
        .background(IslandShape(flare: flare, bottom: fixture.mode == .confirm || fixture.mode == .problem ? 26 : 20).fill(.black))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            switch fixture.mode {
            case .hearing:
                VoiceOrb(level: fixture.level)
                transcript
            case .working, .guide:
                VoiceOrb(level: 0.15, thinking: true)
                Text(fixture.text).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if fixture.mode == .guide {
                    Text(fixture.detail).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.14), in: Circle())
            case .confirm:
                VoiceOrb(level: 0.1)
                Text("Jarvis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            case .problem:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16))
                    .symbolRenderingMode(.palette).foregroundStyle(.black, Color(red: 1, green: 0.62, blue: 0.25))
                    .frame(width: 26, height: 26)
                Text("Jarvis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(height: 34)
    }

    private var transcript: some View {
        let words = Text(fixture.text.isEmpty ? "Listening" : fixture.text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(fixture.text.isEmpty ? .white.opacity(0.55) : .white)
            .lineLimit(1)
            .fixedSize()
        let fits = NSHostingView(rootView: words).fittingSize.width <= 300
        return Group {
            if fits {
                words
            } else {
                words
                    .frame(width: 300, alignment: .trailing)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fixture.text).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !fixture.detail.isEmpty {
                    Text(fixture.detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                pill(fixture.mode == .problem ? "Open Settings" : "Send", primary: true, key: "↩")
                pill(fixture.mode == .problem ? "Dismiss" : "Cancel", primary: false, key: "esc")
                Spacer(minLength: 8)
                if fixture.mode == .confirm {
                    Text("or say “go ahead”").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: 380, alignment: .leading)
        .padding(.top, 6)
    }

    private func pill(_ title: String, primary: Bool, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(key).font(.system(size: 11, weight: .medium)).opacity(0.5)
        }
        .foregroundStyle(primary ? Color.black : Color.white)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.14)), in: Capsule())
    }
}

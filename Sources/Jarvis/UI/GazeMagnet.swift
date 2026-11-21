import AppKit
import Observation
import SwiftUI

/// The gaze highlight's one object ("Magnet"): a hollow glowing orb that
/// follows the gaze and, once the scorer locks onto a control, stretches
/// into a glow hugging that control's whole frame, then shrinks back into
/// the orb when the eyes leave — the iPad pointer, so nothing blinks on
/// and off. Every coordinate is a global top-left screen point; the view
/// draws relative to `canvas`, the frame of the panel it lives in.
struct GazeMagnetState: Equatable {
    struct Lock: Equatable {
        /// Identity of the locked control — a new key is a new glow (it
        /// grows out of the orb), the same key with a moved rect glides.
        var key: String
        var rect: CGRect
        var corner: CGFloat
    }

    var orb: CGPoint?
    var lock: Lock?
    var canvas: CGRect = .zero
    /// Dwell countdown 0…1 — swept around the glow only while dwell can click.
    var progress: Double = 0
    var showsProgress = false
    /// An agent acts on the same element — the glow stands down.
    var dimmed = false
    var reduceMotion = false
}

@MainActor
@Observable
final class GazeMagnetModel {
    var state = GazeMagnetState()
}

/// Draws `GazeMagnetState`. Motion is position, scale and opacity only:
/// the glow is drawn at the control's size and enters by scaling out of
/// the orb's size at the orb's place (and leaves the same way), so no
/// frame or path animates. Reduce Motion swaps the stretch for a
/// crossfade.
struct GazeMagnetView: View {
    var state: GazeMagnetState

    static let orbSide: CGFloat = 56
    static let coreSide: CGFloat = 10
    /// The orb shrinks to this while the glow holds a control.
    static let orbLockedScale: CGFloat = 0.4
    static let dimmedOpacity: Double = 0.3

    var body: some View {
        let locked = state.lock != nil
        ZStack(alignment: .topLeading) {
            if let lock = state.lock {
                MagnetGlow(corner: lock.corner,
                           progress: state.progress,
                           showsProgress: state.showsProgress)
                    .frame(width: lock.rect.width, height: lock.rect.height)
                    .position(local(CGPoint(x: lock.rect.midX, y: lock.rect.midY)))
                    .transition(glowTransition(for: lock))
                    .id(lock.key)
            }
            if let orb = state.orb {
                MagnetOrb()
                    .frame(width: Self.orbSide, height: Self.orbSide)
                    .scaleEffect(locked && !state.reduceMotion ? Self.orbLockedScale : 1)
                    .opacity(locked ? 0 : 1)
                    .position(local(orbPlace(orb)))
                    .transition(.opacity)
            }
        }
        .frame(width: state.canvas.width, height: state.canvas.height, alignment: .topLeading)
        .opacity(state.dimmed ? Self.dimmedOpacity : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// While a glow holds a control the orb gathers into its centre;
    /// under Reduce Motion it stays where it is and only fades.
    private func orbPlace(_ orb: CGPoint) -> CGPoint {
        guard let lock = state.lock, !state.reduceMotion else { return orb }
        return CGPoint(x: lock.rect.midX, y: lock.rect.midY)
    }

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - state.canvas.minX, y: p.y - state.canvas.minY)
    }

    /// The glow grows out of the orb — scaled to the orb's size at the
    /// orb's place — and shrinks back into it on the way out. With no orb
    /// (a press glow while gaze is off) it lifts in place from 96%.
    private func glowTransition(for lock: GazeMagnetState.Lock) -> AnyTransition {
        if state.reduceMotion { return .opacity }
        let center = CGPoint(x: lock.rect.midX, y: lock.rect.midY)
        guard let orb = state.orb else {
            return .modifier(active: MagnetStretch(scale: CGSize(width: 0.96, height: 0.96),
                                                   offset: .zero, opacity: 0),
                             identity: .identity)
        }
        return .modifier(
            active: MagnetStretch(scale: CGSize(width: Self.orbSide / max(lock.rect.width, 1),
                                                height: Self.orbSide / max(lock.rect.height, 1)),
                                  offset: CGSize(width: orb.x - center.x, height: orb.y - center.y),
                                  opacity: 0),
            identity: .identity)
    }
}

/// Transition endpoints for the glow — transforms and opacity only.
private struct MagnetStretch: ViewModifier {
    static let identity = MagnetStretch(scale: CGSize(width: 1, height: 1), offset: .zero, opacity: 1)

    var scale: CGSize
    var offset: CGSize
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}

/// Hollow: a soft glow band around a clear centre, with a crisp ring at
/// the core marking the gaze point without covering the text under it.
private struct MagnetOrb: View {
    var body: some View {
        let glow = Color(nsColor: .controlAccentColor)
        ZStack {
            Circle().fill(RadialGradient(
                stops: [.init(color: glow.opacity(0), location: 0.38),
                        .init(color: glow.opacity(0.55), location: 0.52),
                        .init(color: glow.opacity(0.18), location: 0.64),
                        .init(color: glow.opacity(0), location: 0.72)],
                center: .center, startRadius: 0, endRadius: GazeMagnetView.orbSide / 2))
            Circle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: GazeMagnetView.coreSide, height: GazeMagnetView.coreSide)
                .shadow(color: glow.opacity(0.9), radius: 4)
        }
    }
}

/// The glow hugging a control: an edge-lit gradient stroke with an outer
/// halo and nothing inside, so the control's own label stays legible.
/// While dwell can click, a brighter stroke sweeps the countdown.
private struct MagnetGlow: View {
    var corner: CGFloat
    var progress: Double
    var showsProgress: Bool

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.strokeBorder(
                AngularGradient(colors: [accent, .white.opacity(0.9), accent,
                                         accent.opacity(0.7), accent],
                                center: .center),
                lineWidth: 2)
                .shadow(color: accent.opacity(0.65), radius: 7)
            if showsProgress {
                shape.inset(by: 1)
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        .opacity(TargetOverlay.ringAlpha(progress: progress, dwell: showsProgress))
    }
}

/// The live view: reads the overlay's model, so each change re-renders
/// inside the animation transaction the overlay opened for it.
struct GazeMagnetHost: View {
    let model: GazeMagnetModel

    var body: some View {
        GazeMagnetView(state: model.state)
    }
}

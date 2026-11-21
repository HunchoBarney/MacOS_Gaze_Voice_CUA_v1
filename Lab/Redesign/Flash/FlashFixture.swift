import SwiftUI

/// The moments when Jarvis confirms a target and acts on it: you say
/// "this", it shows what it will press, it presses, it's done.
public struct FlashFixture {
    public enum Phase: String { case aim, this, confirm, press, done }
    public var phase: Phase
    public var target: CGRect = Desk.Target.send
    public var radius: Double = 8
    public var label = "Send"
}

public enum FlashScript {
    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("aim", "Looking at it", caption: "Your gaze rests on Send; the highlight is there, quiet.", duration: 1.0) { _ in FlashFixture(phase: .aim) },
        StateEntry("this", "\u{201C}This\u{201D}", caption: "You say \u{201C}this\u{201D}: Jarvis shows it heard which one you mean.", duration: 1.6) { _ in FlashFixture(phase: .this) },
        StateEntry("confirm", "About to press", caption: "Jarvis names the control it is about to press.", duration: 1.6) { _ in FlashFixture(phase: .confirm) },
        StateEntry("press", "Press", caption: "The press itself: feedback lands on the control, not somewhere else.", duration: 1.0) { _ in FlashFixture(phase: .press) },
        StateEntry("done", "Done", caption: "It worked; the light leaves.", duration: 1.6) { _ in FlashFixture(phase: .done) },
    ]

    public static let flow = ["aim", "this", "confirm", "press", "done"]
}

/// A small dark caption chip, the same type on every direction.
struct FlashCaption: View {
    var text: String
    var dark: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.black.opacity(dark ? 0.82 : 0.78)))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .fixedSize()
    }
}

@MainActor
enum FlashMotion {
    /// The caption under the target fades and drops in 6 pt; under Reduce
    /// Motion it only fades.
    static func caption(_ m: MotionBank, _ c: Ctx, key: String, on: Bool, delay: Double = 0.08) {
        let shown = on && c.local > (c.reduceMotion ? 0 : delay)
        m.set(key, shown ? 1 : 0, shown ? c.fade(.spring(response: 0.32, damping: 0.86)) : c.fade(.easeOut(0.14)))
    }

    static func place(_ text: String, _ f: FlashFixture, _ c: Ctx, _ p: Double) -> some View {
        FlashCaption(text: text, dark: c.dark)
            .opacity(p.clamped(0, 1))
            .offset(y: c.reduceMotion ? 0 : (1 - p) * -6)
            .frame(width: 200)
            .offset(x: f.target.midX - 100, y: f.target.maxY + 10)
    }
}

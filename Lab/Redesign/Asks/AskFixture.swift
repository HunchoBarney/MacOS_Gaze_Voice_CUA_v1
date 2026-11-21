import SwiftUI

/// The richer asks inside the voice surface: check what I heard, an open
/// question answered by voice, a task approval, and a problem to fix. Text
/// is the product's gallery fixtures (GalleryRenderTests indicatorFixtures).
public struct AskFixture {
    public enum Phase: String {
        case idle, review = "asking-review", question = "asking-question", approval = "asking-approval", problem
    }
    public var phase: Phase
    /// The bigger-labels comfort setting (Config.labelScale): 1 to 2 in quarter steps.
    public var labelScale: Double = 1
    /// Microphone level while Jarvis waits for a spoken answer.
    public var level: Double = 0
}

public enum AskScript {
    static let heard = "Reply to Alex and say the deck is ready"
    static let question = "Which deck: Q3 planning or Q3 review?"
    static let approval = "Move 14 receipts from Downloads into Expenses?"
    static let from = "Downloads"
    static let to = "Expenses"
    static let problemTitle = "I couldn't reach OpenAI just now."
    static let problemDetail = "Check your internet connection, then try again."

    /// The two answers an ask accepts by key, with the phrase that does the same.
    static func actions(_ phase: AskFixture.Phase) -> (primary: String?, secondary: String, say: String?) {
        switch phase {
        case .review: return ("Continue", "Cancel", "continue")
        case .question: return (nil, "Cancel", nil)
        case .approval: return ("Go ahead", "Cancel", "go ahead")
        case .problem: return ("Open Settings", "Dismiss", nil)
        case .idle: return (nil, "", nil)
        }
    }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("idle", "Idle", caption: "Nothing on screen but the notch.", duration: 0.8) { _ in AskFixture(phase: .idle) },
        StateEntry("asking-review", "Check what I heard", caption: "Before a consequential request, Jarvis shows the words it heard: continue, cancel, or say it again.", duration: 3.0) { _ in
            AskFixture(phase: .review)
        },
        StateEntry("asking-question", "A question", caption: "An open question: you answer by voice, so the surface listens; the only button is Cancel.", duration: 3.0) { t in
            AskFixture(phase: .question, level: VoiceScript.noise(t))
        },
        StateEntry("asking-approval", "Task approval", caption: "A task that changes files waits for your go-ahead, and shows what moves where.", duration: 3.0) { _ in
            AskFixture(phase: .approval)
        },
        StateEntry("problem", "Problem", caption: "Something failed that you have to read: what happened, what to do, and the way to fix it.", duration: 3.0) { _ in
            AskFixture(phase: .problem)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "Bigger labels at 2\u{00D7}: the approval's type, tags and buttons double, and the surface grows to hold them.", duration: 3.0) { _ in
            AskFixture(phase: .approval, labelScale: 2)
        },
        StateEntry("large-review", "Largest labels, heard words (2\u{00D7})", caption: "Check what I heard at 2\u{00D7}: the heard words wrap rather than run under the buttons.", duration: 3.0) { _ in
            AskFixture(phase: .review, labelScale: 2)
        },
    ]

    public static let flow = ["idle", "asking-review", "asking-question", "asking-approval", "problem", "idle", "large", "large-review", "idle"]
}

/// An ask's buttons with the phrase that does the same. The phrase sits at
/// the row's end, and drops under the buttons when larger labels leave no room.
struct AnswerRow<Buttons: View>: View {
    var say: String?
    var color: Color
    var scale: CGFloat = 1
    var centered = false
    @ViewBuilder var buttons: Buttons

    var body: some View {
        let line = Text(say.map { "or say \u{201C}\($0)\u{201D}" } ?? "")
            .font(.system(size: 12 * scale)).foregroundStyle(color).fixedSize()
        if centered {
            VStack(spacing: 6 * scale) {
                HStack(spacing: 10 * scale) { buttons }
                if say != nil { line }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8 * scale) {
                    buttons
                    Spacer(minLength: 8 * scale)
                    if say != nil { line }
                }
                VStack(alignment: .leading, spacing: 8 * scale) {
                    HStack(spacing: 8 * scale) { buttons }
                    if say != nil { line }
                }
            }
        }
    }
}

/// A folder named in an approval, as a small tag.
struct FolderTag: View {
    var name: String
    var ink: Color
    var fill: Color
    var scale: CGFloat = 1
    var body: some View {
        HStack(spacing: 5 * scale) {
            Image(systemName: "folder.fill").font(.system(size: 11 * scale)).foregroundStyle(Color(red: 0.36, green: 0.66, blue: 1))
            Text(name).font(.system(size: 12.5 * scale, weight: .medium)).foregroundStyle(ink)
        }
        .padding(.horizontal, 9 * scale)
        .frame(height: 24 * scale)
        .background(fill, in: RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
        .fixedSize()
    }
}

/// Downloads → Expenses.
struct MoveRow: View {
    var ink: Color
    var sub: Color
    var fill: Color
    var scale: CGFloat = 1
    var body: some View {
        HStack(spacing: 8 * scale) {
            FolderTag(name: AskScript.from, ink: ink, fill: fill, scale: scale)
            Image(systemName: "arrow.right").font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(sub)
            FolderTag(name: AskScript.to, ink: ink, fill: fill, scale: scale)
        }
    }
}

@MainActor
enum AskMotion {
    static let phases: [AskFixture.Phase] = [.review, .question, .approval, .problem]

    /// Each ask's content: the old one leaves fast, the new one arrives after
    /// `delay` so the container's shape leads.
    static func content(_ f: AskFixture, _ c: Ctx, _ m: MotionBank, delay: Double, enter: Double = 0.24) {
        for phase in phases {
            let on = f.phase == phase && c.local > (c.reduceMotion ? 0 : delay)
            m.set("c." + phase.rawValue, on ? 1 : 0, on ? c.fade(.easeOut(enter)) : c.fade(.easeOut(0.12)))
        }
    }

}

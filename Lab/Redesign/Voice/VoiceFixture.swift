import AppKit
import SwiftUI

/// What the voice surface is showing, from fixture time only.
public struct VoiceFixture {
    public enum Phase: String { case idle, listening, hearing, working, asking, done, problem }

    public var phase: Phase
    /// Words heard so far, with how long ago each arrived.
    public var words: [(text: String, age: Double)] = []
    /// Microphone level 0...1.
    public var level: Double = 0
    public var label = ""
    public var question = ""
    public var detail = ""
    public var options: [String] = []
    public var problemTitle = ""
    public var problemDetail = ""
    public var problemAction = ""

    public var transcript: String { words.map(\.text).joined(separator: " ") }
}

public enum VoiceScript {
    public static let utterance = "Reply to Alex and say the deck is ready".split(separator: " ").map(String.init)
    static let firstWord = 0.18
    static let wordGap = 0.26

    /// A speech-like level: syllable bursts under a phrase envelope.
    static func speech(_ t: Double, until end: Double) -> Double {
        guard t < end + 0.35 else { return 0.02 }
        let fade = t > end ? max(0, 1 - (t - end) / 0.35) : min(1, t / 0.12)
        let syllables = 0.5 + 0.5 * sin(t * 21.0) * sin(t * 7.3 + 0.6)
        let phrase = 0.55 + 0.25 * sin(t * 2.1 + 1.1)
        return max(0.02, min(1, fade * (0.15 + syllables * phrase)))
    }

    static func noise(_ t: Double) -> Double { 0.04 + 0.03 * (0.5 + 0.5 * sin(t * 13.0) * sin(t * 4.1)) }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("idle", "Idle", caption: "Nothing on screen but the notch.", duration: 1.0) { _ in VoiceFixture(phase: .idle) },
        StateEntry("listening", "Wake word heard", caption: "Jarvis is listening; you haven't spoken yet.", duration: 1.5) { t in
            VoiceFixture(phase: .listening, level: noise(t))
        },
        StateEntry("hearing", "Hearing you", caption: "Words arrive live as you speak.", duration: 3.6) { t in
            let end = firstWord + wordGap * Double(utterance.count - 1) + 0.2
            var f = VoiceFixture(phase: .hearing, level: speech(t, until: end))
            for (i, word) in utterance.enumerated() {
                let at = firstWord + wordGap * Double(i)
                if t >= at { f.words.append((word, t - at)) }
            }
            return f
        },
        StateEntry("working", "Working", caption: "Jarvis is doing it; you can stop it.", duration: 2.6) { _ in
            VoiceFixture(phase: .working, label: "Replying to Alex")
        },
        StateEntry("asking", "Asking", caption: "A consequential step waits for your yes.", duration: 3.4) { _ in
            VoiceFixture(phase: .asking, question: "Send this to Alex?", detail: "The deck is ready.", options: ["Send", "Edit first"])
        },
        StateEntry("done", "Done", caption: "It happened; then the surface goes away.", duration: 1.8) { _ in
            VoiceFixture(phase: .done, label: "Sent")
        },
        StateEntry("problem", "Problem", caption: "Something you have to read and can fix.", duration: 3.2) { _ in
            VoiceFixture(phase: .problem, problemTitle: "Mail didn't respond",
                         problemDetail: "Allow Jarvis to control Mail in Privacy & Security.", problemAction: "Open Settings")
        },
    ]

    public static let flow = ["idle", "listening", "hearing", "working", "asking", "done", "idle"]
}

enum TextMetrics {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .medium) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

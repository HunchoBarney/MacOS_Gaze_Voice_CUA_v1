import Foundation

/// How long Jarvis's spoken answers run. The Realtime session instructions
/// carry it, so the next reply follows it.
enum ReplyLength: String, CaseIterable, Sendable {
    case shorter, standard, detailed
}

/// The speed of Jarvis's voice, the Realtime session's
/// `audio.output.speed`. OpenAI accepts 0.25–1.5 with 1.0 as the default and
/// applies it between turns, never during a reply in progress. Jarvis keeps
/// to a band inside that where speech stays natural: three steps slower, two
/// faster.
enum SpeechSpeed {
    static let standard = 1.0
    static let range = 0.55...1.3
    static let step = 0.15
}

/// The size of the labels Jarvis draws over the screen (number and name
/// chips, the cheat sheet), as a multiple of their designed size. The
/// designed size is the smallest; four steps make them twice as big.
enum LabelScale {
    static let standard = 1.0
    static let range = 1.0...2.0
    static let step = 0.25
}

/// A spoken comfort preference: "talk slower", "shorter answers",
/// "bigger labels".
enum ComfortChange: Equatable, Sendable {
    enum Step: Equatable, Sendable { case down, up, reset }

    case speech(Step)
    case replies(ReplyLength)
    case labels(Step)

    /// The next value one step along, or nil when the value is already at
    /// that end of its range. Values snap to hundredths so repeated steps
    /// land exactly on the range's ends.
    static func stepped(_ value: Double, _ step: Step, standard: Double, by size: Double,
                        in range: ClosedRange<Double>) -> Double? {
        let next: Double
        switch step {
        case .reset: next = standard
        case .down: next = max(range.lowerBound, value - size)
        case .up: next = min(range.upperBound, value + size)
        }
        let snapped = (next * 100).rounded() / 100
        return snapped == value && step != .reset ? nil : snapped
    }

    /// Applies the change to the app's Config.
    @MainActor
    func applyToSharedConfig() -> String { apply(to: .shared) }

    /// Applies the change to `config` and returns what Jarvis says about it.
    @MainActor
    func apply(to config: Config) -> String {
        switch self {
        case .speech(let step):
            guard let speed = Self.stepped(config.speechSpeed, step, standard: SpeechSpeed.standard,
                                           by: SpeechSpeed.step, in: SpeechSpeed.range) else {
                return step == .down ? "I'm already talking as slowly as I can."
                    : "I'm already talking as fast as I can."
            }
            config.speechSpeed = speed
            switch step {
            case .down: return "Okay, I'll talk slower."
            case .up: return "Okay, I'll talk faster."
            case .reset: return "Okay, I'll talk at my normal speed."
            }
        case .replies(let length):
            config.replyLength = length
            switch length {
            case .shorter: return "Okay, I'll keep my answers short."
            case .detailed: return "Okay, I'll give you more detail."
            case .standard: return "Okay, back to my usual answers."
            }
        case .labels(let step):
            guard let scale = Self.stepped(config.labelScale, step, standard: LabelScale.standard,
                                           by: LabelScale.step, in: LabelScale.range) else {
                return step == .down ? "The labels are already as small as they go."
                    : "The labels are already as big as they go."
            }
            config.labelScale = scale
            switch step {
            case .down: return "Okay, I'll make the labels smaller."
            case .up: return "Okay, I'll make the labels bigger."
            case .reset: return "Okay, the labels are back to their normal size."
            }
        }
    }
}

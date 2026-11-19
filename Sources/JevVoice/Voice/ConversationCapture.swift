import Foundation

struct ConversationUtterance: Sendable {
    let session: UUID
    let id: UUID
    let samples: [Float]
    let range: Range<Int>
    let detectedAt: TimeInterval
    let sealedAt: TimeInterval
}

enum ConversationCaptureEvent: Sendable {
    case began(session: UUID, id: UUID, sample: Int, detectedAt: TimeInterval)
    case utterance(ConversationUtterance)
}

protocol ConversationSegmenter: Actor {
    func prepare() async throws
    func begin(session: UUID) throws -> AsyncThrowingStream<ConversationCaptureEvent, Error>
    func consume(_ frame: VoicePCMFrame, session: UUID) async throws
    func acknowledge(_ utterance: ConversationUtterance)
    func stop(session: UUID)
}

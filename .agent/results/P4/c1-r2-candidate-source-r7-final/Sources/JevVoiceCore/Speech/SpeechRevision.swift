import Foundation

/// Decision provenance: which voice capture submitted the work.
public struct SpeechProvenance: Sendable, Equatable {
    public let captureID: UUID
    public init(captureID: UUID) { self.captureID = captureID }
}

import Foundation
import JevVoiceCore

protocol LocalTranscriptProvider: Actor {
    nonisolated var evidenceSink: CallbackCell<VoiceSpeechDiagnostic>? { get }
    nonisolated var readyForTurn: Bool { get }
    nonisolated var preparedForCapture: Bool { get }
    func prepare() async throws
    func beginHold(_ turn: VoiceTurnToken, partial: @escaping @Sendable (VoiceTurnToken, String) -> Void) async throws
    func beginRecordedUtterance(_ turn: VoiceTurnToken) async throws
    func appendHold(_ turn: VoiceTurnToken, frame: VoicePCMFrame) async throws
    func finishHold(_ turn: VoiceTurnToken) async throws -> String
    func cancelHold(_ turn: VoiceTurnToken) async
}

extension LocalTranscriptProvider {
    nonisolated var evidenceSink: CallbackCell<VoiceSpeechDiagnostic>? { nil }
    func beginRecordedUtterance(_ turn: VoiceTurnToken) async throws {
        try await beginHold(turn) { _, _ in }
    }
}

import XCTest
import JevVoiceCore
@testable import JevVoice

/// Real microphone, programmatic admission, no Jev/Cua calls and no retained speech.
/// Run only under scripts/with-desktop-lock.py with the exact opt-in below.
@MainActor
final class ReadyMicrophoneLiveTests: XCTestCase {
    func testReadyMicrophoneAdmissionAcrossHoldsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_READY_MIC_TEST"] == "1" else {
            throw XCTSkip("Opt-in real microphone lifetime/timing check; no desktop actions")
        }
        guard Permission.microphone.isGranted else {
            return XCTFail("Microphone permission is required for the requested live check")
        }
        let openAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        guard !openAIKey.isEmpty else {
            throw XCTSkip("Realtime lane needs OPENAI_API_KEY for its socket")
        }
        let capture = RealtimeVoiceLane(apiKey: { openAIKey })
        // Transcript-only commits: no response.create, so `.final` is the
        // terminal event — the same shape the dictation path uses.
        capture.respondOnCommit = false
        let uid = ProcessInfo.processInfo.environment["JARVIS_TEST_MIC_UID"]
        var current: UUID?, firstAudio: Double?, finalized = false, failure: String?
        capture.onEvent = { id, event in
            guard id == current else { return }
            switch event {
            case .timing("Capture call to first audio", let milliseconds): firstAudio = milliseconds
            case .final: finalized = true
            case .failure(let message): failure = message
            default: break
            }
        }
        do {
            let cold = ProcessInfo.processInfo.systemUptime
            let name = try await capture.prepare(inputUID: uid)
            print("READY_MIC cold_preparation_ms", (ProcessInfo.processInfo.systemUptime - cold) * 1000, "device", name)
            var samples: [Double] = []
            for index in 0..<30 {
                _ = try await capture.prepare(inputUID: uid)
                // Idle device audio must never produce a session callback.
                current = nil
                try await Task.sleep(for: .milliseconds(50))
                let id = UUID(); current = id; firstAudio = nil; finalized = false; failure = nil
                _ = try await capture.start(session: id, inputUID: uid, transcribe: true)
                for _ in 0..<100 where firstAudio == nil && failure == nil { try await Task.sleep(for: .milliseconds(10)) }
                let first = try XCTUnwrap(firstAudio, "No audio for hold \(index): \(failure ?? "")")
                samples.append(first)
                capture.finish()
                for _ in 0..<200 where !finalized && failure == nil { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertNil(failure)
                XCTAssertTrue(finalized, "Hold \(index) must have a terminal result")
                print("READY_MIC sample", index, "first_audio_ms", first, "finalized", finalized)
                capture.cancel()
            }
            let sorted = samples.sorted()
            print("READY_MIC summary samples", sorted.count, "median_ms", (sorted[14] + sorted[15]) / 2,
                  "p95_ms", sorted[28], "max_ms", sorted[29])
            // Verify device teardown/recovery produces a fresh independent session.
            await capture.suspend()
            _ = try await capture.prepare(inputUID: uid)
            let id = UUID(); current = id; firstAudio = nil; failure = nil
            _ = try await capture.start(session: id, inputUID: uid, transcribe: true)
            for _ in 0..<100 where firstAudio == nil && failure == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(firstAudio); XCTAssertNil(failure)
            capture.cancel()
        } catch {
            await capture.suspend()
            throw error
        }
        await capture.suspend()
    }
}

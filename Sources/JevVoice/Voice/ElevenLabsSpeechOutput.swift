import AVFoundation
import Foundation

/// Spoken replies over the ElevenLabs TTS API behind the `SpeechSynthesizing`
/// seam — the cloud counterpart to `SpeechOutput`'s system voice.
///
/// `speak` fires one `text-to-speech` request per call and plays the returned
/// audio on the main queue, so callers never block. A new `speak` barges in:
/// it cancels the in-flight request and stops the current player.
///
/// Failure posture is degrade, never silence: an empty key, a network fault,
/// or a non-2xx reply falls through to the system-voice fallback so the user
/// still hears the reply.
final class ElevenLabsSpeechOutput: SpeechSynthesizing, @unchecked Sendable {
    /// Mirrors Config.ttsEnabled; disabled output drops calls silently —
    /// the fallback is never reached, so no speech escapes either path.
    var enabled: Bool
    /// Set when config resolves the credential; an empty key routes every
    /// call to the system fallback.
    var apiKey: String
    var voiceID: String
    var modelID: String
    private let fallback: SpeechSynthesizing
    private let session: URLSession
    private let makePlayer: (Data) throws -> AVAudioPlayer
    private var task: URLSessionDataTask?
    private var player: AVAudioPlayer?
    /// Barge-in invalidation: a response from a superseded request is dropped.
    private var generation = 0

    init(apiKey: String = "", voiceID: String = "21m00Tcm4TlvDq8ikWAM",
         modelID: String = "eleven_flash_v2_5",
         session: URLSession = .shared,
         fallback: SpeechSynthesizing = SpeechOutput(), enabled: Bool = true,
         makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) }) {
        self.apiKey = apiKey; self.voiceID = voiceID; self.modelID = modelID
        self.session = session; self.fallback = fallback; self.enabled = enabled
        self.makePlayer = makePlayer
    }

    /// Builds the TTS request — exposed for tests so the contract (endpoint,
    /// auth header, model field) is verified without network.
    func request(for text: String) -> URLRequest? {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "model_id": modelID,
            "voice_settings": ["stability": 0.5]
        ])
        return request
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        generation += 1
        let token = generation
        task?.cancel(); task = nil
        guard enabled else { return }
        guard let request = request(for: trimmed) else {
            fallback.speak(trimmed)
            return
        }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                if ok, let data, !data.isEmpty, error == nil,
                   let player = try? self.makePlayer(data) {
                    self.player?.stop()
                    self.player = player
                    player.play()
                } else {
                    self.fallback.speak(trimmed)
                }
            }
        }
        self.task = task
        task.resume()
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        DispatchQueue.main.async { self.player?.stop() }
        fallback.stop()
    }
}

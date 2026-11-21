import AVFoundation
import Foundation

/// Spoken replies over AVSpeechSynthesizer behind the `SpeechSynthesizing`
/// seam. `speak` and `stop` never block: every call hops to the main queue,
/// where the synthesizer is created and driven. A new `speak` barges in on
/// the current utterance.
final class SpeechOutput: SpeechSynthesizing, VoicePlaybackRouting, @unchecked Sendable {
    /// Mirrors Config.ttsEnabled; disabled output drops calls silently.
    var enabled: Bool
    /// AVSpeechUtterance rate (0…1); AVSpeechUtteranceDefaultSpeechRate ≈ 0.5.
    var rate: Float
    private var synthesizer: AVSpeechSynthesizer?
    private let route = LockedBox<VoicePlaybackRoute?>(nil)
    private let synthesisEpoch = LockedBox(UUID())
    private let player = RealtimePlayer()
    private let conversionQueue = DispatchQueue(label: "voice.system.synthesis", qos: .userInitiated)
    private var converted: ConvertedAudioFeed?
    private var consumer: Task<Void, Never>?
    var playbackChannel: VoicePlaybackChannel { .system }
    var playbackActive: Bool { !player.playbackIdle }
    /// Whether anything is being spoken, routed or not. Read on the main
    /// thread, where the synthesizer lives.
    var speaking: Bool { playbackActive || (synthesizer?.isSpeaking ?? false) }

    init(rate: Float = AVSpeechUtteranceDefaultSpeechRate, enabled: Bool = true) {
        self.rate = rate
        self.enabled = enabled
    }

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let epoch = UUID()
        synthesisEpoch.set(epoch)
        _ = player.interrupt()
        resetConversion(epoch: epoch)
        DispatchQueue.main.async {
            guard self.synthesisEpoch.value == epoch, self.enabled else { return }
            let synthesizer = self.synthesizerOnMain()
            if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = self.rate
            guard let route = self.route.value else {
                synthesizer.speak(utterance)
                return
            }
            guard route.isReady() else { return }
            let owner = self.player.generationToken
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self, self.synthesisEpoch.value == epoch,
                      let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    self.conversionQueue.async {
                        guard self.synthesisEpoch.value == epoch else { return }
                        self.converted?.finish()
                    }
                    return
                }
                do {
                    let frame = try VoicePCMFrame(copying: pcm)
                    self.convert(frame, epoch: epoch, owner: owner)
                } catch {
                    self.stopIfCurrent(epoch, owner: owner)
                }
            }
        }
    }

    func stop() {
        let epoch = UUID()
        synthesisEpoch.set(epoch)
        _ = player.interrupt()
        resetConversion(epoch: epoch)
        DispatchQueue.main.async {
            guard self.synthesisEpoch.value == epoch else { return }
            self.synthesizer?.stopSpeaking(at: .immediate)
        }
    }

    func setPlaybackRoute(_ route: VoicePlaybackRoute?) {
        stop()
        self.route.set(route)
        player.setPlaybackRoute(route)
    }

    private func resetConversion(epoch: UUID) {
        conversionQueue.async {
            guard self.synthesisEpoch.value == epoch else { return }
            self.consumer?.cancel()
            self.converted?.finish()
            self.consumer = nil
            self.converted = nil
        }
    }

    private func stopIfCurrent(_ epoch: UUID, owner: UInt64) {
        conversionQueue.async {
            guard self.synthesisEpoch.value == epoch else { return }
            self.consumer?.cancel()
            self.converted?.finish()
            _ = self.player.interrupt(owner: owner)
            DispatchQueue.main.async {
                guard self.synthesisEpoch.value == epoch else { return }
                self.synthesizer?.stopSpeaking(at: .immediate)
            }
        }
    }

    private func convert(_ frame: VoicePCMFrame, epoch: UUID, owner: UInt64) {
        conversionQueue.async {
            guard self.synthesisEpoch.value == epoch else { return }
            do {
                let buffer = try frame.buffer()
                if self.converted == nil {
                    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                        sampleRate: 24_000, channels: 1, interleaved: true) else {
                        throw VoiceError("Could not prepare spoken audio.")
                    }
                    let feed = try ConvertedAudioFeed(input: buffer.format, output: format)
                    self.converted = feed
                    self.consumer = Task { [weak self] in
                        do {
                            for try await buffer in feed.stream {
                                guard let self, self.synthesisEpoch.value == epoch, !Task.isCancelled else { return }
                                let pcm = try VoicePCMFrame(copying: buffer)
                                self.player.enqueue(pcm.bytes, itemID: "system-\(epoch)", owner: owner)
                            }
                        } catch {
                            self?.stopIfCurrent(epoch, owner: owner)
                        }
                    }
                }
                self.converted?.append(buffer)
            } catch {
                self.stopIfCurrent(epoch, owner: owner)
            }
        }
    }

    private func synthesizerOnMain() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        return synthesizer
    }
}

import AVFoundation
import Foundation
import OSLog
import os

/// The Vosk C API (Alpha Cephei, Apache-2.0) and its small English model,
/// loaded at runtime from `Resources/Vosk` in the app or `build/vendor/Vosk`
/// in a checkout (`ThirdParty/Vosk/fetch.sh`). One model is shared; each
/// recognizer belongs to one thread at a time.
final class Vosk: @unchecked Sendable {
    typealias Handle = OpaquePointer

    private let model: Handle
    private let findWord: @convention(c) (Handle, UnsafePointer<CChar>) -> Int32
    private let newRecognizer: @convention(c) (Handle, Float, UnsafePointer<CChar>) -> Handle?
    private let setWords: @convention(c) (Handle, Int32) -> Void
    private let acceptWaveform: @convention(c) (Handle, UnsafePointer<Int16>, Int32) -> Int32
    private let partialResult: @convention(c) (Handle) -> UnsafePointer<CChar>?
    private let result: @convention(c) (Handle) -> UnsafePointer<CChar>?
    private let finalResult: @convention(c) (Handle) -> UnsafePointer<CChar>?
    private let reset: @convention(c) (Handle) -> Void
    private let freeRecognizer: @convention(c) (Handle) -> Void

    private static let loaded = NSLock()
    nonisolated(unsafe) private static var cached: Vosk?

    static func shared() throws -> Vosk {
        loaded.lock(); defer { loaded.unlock() }
        if let cached { return cached }
        guard let directory = directory() else { throw VoiceError("The wake-word engine is missing from this build.") }
        let vosk = try Vosk(directory: directory)
        cached = vosk
        return vosk
    }

    static func directory() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Vosk", isDirectory: true)
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/vendor/Vosk", isDirectory: true)
        return [bundled, checkout].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("libvosk.dylib").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("model/am/final.mdl").path)
        }
    }

    private init(directory: URL) throws {
        guard let library = dlopen(directory.appendingPathComponent("libvosk.dylib").path, RTLD_NOW | RTLD_LOCAL) else {
            throw VoiceError("The wake-word engine can't load: \(String(cString: dlerror()))")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw VoiceError("The wake-word engine is missing \(name).") }
            return unsafeBitCast(pointer, to: T.self)
        }
        try symbol("vosk_set_log_level", (@convention(c) (Int32) -> Void).self)(-1)
        let newModel = try symbol("vosk_model_new", (@convention(c) (UnsafePointer<CChar>) -> Handle?).self)
        findWord = try symbol("vosk_model_find_word", (@convention(c) (Handle, UnsafePointer<CChar>) -> Int32).self)
        newRecognizer = try symbol("vosk_recognizer_new_grm", (@convention(c) (Handle, Float, UnsafePointer<CChar>) -> Handle?).self)
        setWords = try symbol("vosk_recognizer_set_words", (@convention(c) (Handle, Int32) -> Void).self)
        acceptWaveform = try symbol("vosk_recognizer_accept_waveform_s", (@convention(c) (Handle, UnsafePointer<Int16>, Int32) -> Int32).self)
        partialResult = try symbol("vosk_recognizer_partial_result", (@convention(c) (Handle) -> UnsafePointer<CChar>?).self)
        result = try symbol("vosk_recognizer_result", (@convention(c) (Handle) -> UnsafePointer<CChar>?).self)
        finalResult = try symbol("vosk_recognizer_final_result", (@convention(c) (Handle) -> UnsafePointer<CChar>?).self)
        reset = try symbol("vosk_recognizer_reset", (@convention(c) (Handle) -> Void).self)
        freeRecognizer = try symbol("vosk_recognizer_free", (@convention(c) (Handle) -> Void).self)
        guard let model = newModel(directory.appendingPathComponent("model").path) else {
            throw VoiceError("The wake-word model can't load.")
        }
        self.model = model
    }

    /// Whether the model can hear `word`; a grammar silently drops any it can't.
    func knows(_ word: String) -> Bool { findWord(model, word) >= 0 }

    /// A recognizer that may only hear the given phrases, or `[unk]`.
    final class Recognizer {
        private let vosk: Vosk
        private let handle: Handle

        init(_ vosk: Vosk, sampleRate: Double, phrases: [String], words: Bool = false) throws {
            let grammar = String(decoding: try JSONSerialization.data(withJSONObject: phrases + ["[unk]"]), as: UTF8.self)
            guard let handle = vosk.newRecognizer(vosk.model, Float(sampleRate), grammar) else {
                throw VoiceError("The wake-word recognizer can't start.")
            }
            if words { vosk.setWords(handle, 1) }
            self.vosk = vosk
            self.handle = handle
        }

        deinit { vosk.freeRecognizer(handle) }

        /// Feeds audio and returns what the recognizer hears so far: the
        /// finished utterance when one ended, else the partial one.
        func hear(_ samples: [Int16]) -> String {
            accept(samples) ? Self.decode(vosk.result(handle)).text ?? "" : Self.decode(vosk.partialResult(handle)).partial ?? ""
        }

        /// Decodes a whole clip and returns its words, then starts over.
        func words(in samples: [Int16]) -> [Word] {
            accept(samples)
            defer { restart() }
            return Self.decode(vosk.finalResult(handle)).result ?? []
        }

        func restart() { vosk.reset(handle) }

        @discardableResult
        private func accept(_ samples: [Int16]) -> Bool {
            samples.withUnsafeBufferPointer { vosk.acceptWaveform(handle, $0.baseAddress!, Int32($0.count)) } != 0
        }

        struct Word: Decodable { var word: String; var conf: Double }
        private struct Output: Decodable { var text: String?; var partial: String?; var result: [Word]? }

        private static func decode(_ json: UnsafePointer<CChar>?) -> Output {
            guard let json else { return Output() }
            return (try? JSONDecoder().decode(Output.self, from: Data(String(cString: json).utf8))) ?? Output()
        }
    }
}

/// Hears "Hey <name>" in 16 kHz mono audio, in two passes over Vosk.
/// A listener that knows only the wake phrase runs on every buffer. When it
/// hears the phrase, the 2.5 s before and 1 s after are decoded again by a
/// checker that also knows "Hey <first name>" for every name in the system
/// list (`/usr/share/dict/propernames`), so "Hey Jack" isn't taken for
/// "Hey Jake". The phrase counts when each word scores at least 0.6.
final class WakePhraseSpotter {
    static let sampleRate = 16_000.0
    static let confidence = 0.6

    let phrase: [String]
    private let listener: Vosk.Recognizer
    private let checker: Vosk.Recognizer
    private let before = Int(sampleRate * 2.5)
    private let after = Int(sampleRate * 1.0)
    private var recent: [Int16] = []
    private var awaiting: Int?

    /// The listener heard the phrase and the checker is waiting for the
    /// second after it.
    var confirming: Bool { awaiting != nil }

    init(name: String, vosk: Vosk) throws {
        let words = Self.words(name)
        guard !words.isEmpty else { throw VoiceError("The assistant needs a name.") }
        if let unknown = words.first(where: { !vosk.knows($0) }) {
            throw VoiceError("The wake word can't hear \"\(unknown)\". Pick another name.")
        }
        phrase = ["hey"] + words
        let wake = phrase.joined(separator: " ")
        listener = try Vosk.Recognizer(vosk, sampleRate: Self.sampleRate, phrases: [wake])
        checker = try Vosk.Recognizer(vosk, sampleRate: Self.sampleRate,
                                      phrases: [wake] + Self.rivals(excluding: Set(words)).filter(vosk.knows).map { "hey \($0)" }, words: true)
    }

    /// Lowercased words of a typed name, as the model spells them.
    static func words(_ name: String) -> [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    static func rivals(excluding names: Set<String>) -> [String] {
        guard let list = try? String(contentsOfFile: "/usr/share/dict/propernames", encoding: .utf8) else { return [] }
        return Set(list.split(whereSeparator: \.isNewline).map { $0.lowercased() }
            .filter { $0.allSatisfy(\.isLetter) && !names.contains($0) }).sorted()
    }

    /// Feeds 16 kHz mono audio; true once per heard wake phrase.
    func accept(_ samples: [Int16]) -> Bool {
        recent += samples
        if recent.count > before + after { recent.removeFirst(recent.count - before - after) }
        if let remaining = awaiting {
            guard remaining <= samples.count else { awaiting = remaining - samples.count; return false }
            awaiting = nil
            return confirmed(recent)
        }
        guard Self.contains(phrase, in: listener.hear(samples).split(separator: " ").map(String.init)) else { return false }
        listener.restart()
        awaiting = after
        return false
    }

    private func confirmed(_ window: [Int16]) -> Bool {
        let heard = checker.words(in: window + [Int16](repeating: 0, count: Int(Self.sampleRate / 2)))
        return heard.indices.contains { start in
            let span = heard[start...].prefix(phrase.count)
            return span.map(\.word) == phrase && span.allSatisfy { $0.conf >= Self.confidence }
        }
    }

    private static func contains(_ phrase: [String], in words: [String]) -> Bool {
        words.count >= phrase.count && (0...(words.count - phrase.count)).contains { Array(words[$0..<$0 + phrase.count]) == phrase }
    }
}

/// The wake-word engine for Standby. It hears the voice lane's own
/// microphone tap (the chosen microphone), converts it to 16 kHz and
/// spots on a background queue. Nothing leaves the Mac.
final class VoskWakeWordDetector: WakeWordDetecting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.karanvirkang.jarvis.wake-word", qos: .userInitiated)
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: WakePhraseSpotter.sampleRate,
                                       channels: 1, interleaved: true)!
    private let listening = OSAllocatedUnfairLock(initialState: false)
    private var spotter: WakePhraseSpotter?
    private var spotterName = ""
    private var converter: AVAudioConverter?
    private var heard: (@MainActor (TimeInterval) -> Void)?
    private var triggeredAt: TimeInterval = 0

    /// The model loads on the detector's queue, so the first start returns
    /// before it's ready and audio heard meanwhile is skipped.
    func start(name: String, heard: @escaping @MainActor (TimeInterval) -> Void) throws {
        guard Vosk.directory() != nil else { throw VoiceError("The wake-word engine is missing from this build.") }
        listening.withLock { $0 = true }
        queue.async {
            do {
                if self.spotter == nil || self.spotterName != name {
                    self.spotter = nil
                    self.spotter = try WakePhraseSpotter(name: name, vosk: try Vosk.shared())
                    self.spotterName = name
                }
                self.heard = heard
            } catch {
                Self.log.error("wake word unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let log = Logger(subsystem: "com.karanvirkang.jarvis.voice", category: "wake-word")

    func problem(with name: String) -> String? {
        if let problem = AssistantName.problem(with: name) { return problem }
        guard let vosk = try? Vosk.shared() else { return "The wake-word engine is missing from this build." }
        guard let unknown = WakePhraseSpotter.words(name).first(where: { !vosk.knows($0) }) else { return nil }
        return "Jarvis can't listen for “\(unknown.capitalized)” reliably yet. Pick a common name, like Nova or Max."
    }

    func stop() {
        listening.withLock { $0 = false }
        queue.async { self.heard = nil }
    }

    func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard listening.withLock({ $0 }), time.isHostTimeValid, let copy = Self.copy(buffer) else { return }
        let ended = AVAudioTime.seconds(forHostTime: time.hostTime) + Double(buffer.frameLength) / buffer.format.sampleRate
        queue.async { self.spot(copy, endingAt: ended) }
    }

    private func spot(_ buffer: AVAudioPCMBuffer, endingAt ended: TimeInterval) {
        guard let spotter, let heard else { return }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: output) }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity:
                AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 16) else { return }
        var fed = false
        converter.convert(to: converted, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        let confirming = spotter.confirming
        let woke = spotter.accept(Array(UnsafeBufferPointer(start: converted.int16ChannelData![0], count: Int(converted.frameLength))))
        if !confirming, spotter.confirming { triggeredAt = ended }
        guard woke else { return }
        let at = triggeredAt
        Task { @MainActor in heard(at) }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData else { return nil }
            memcpy(to, from, Int(min(source[index].mDataByteSize, target[index].mDataByteSize)))
        }
        return copy
    }
}

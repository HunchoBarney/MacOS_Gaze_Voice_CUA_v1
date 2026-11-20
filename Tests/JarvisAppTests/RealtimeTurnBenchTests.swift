import AVFoundation
import Foundation
import XCTest
@testable import Jarvis
import JarvisCore

/// Phase 1 (paid, owner-approved, JARA-42): real Realtime sessions fed with
/// rendered speech instead of a microphone, through the production client
/// and its session configuration. Measures the server's share of
/// release-to-action and of the hands-free turn end:
///
/// - `fn`: manual input mode. Speech streams at real time, then the buffer
///   is committed the way a Fn release commits it; the clock runs from the
///   commit to the completed input transcript.
/// - `handsfree`: conversation mode, where the Mac ends the turn. The same
///   audio (speech, then quiet room noise) runs through the production
///   VoiceActivityGate with the Silero model; what it uploads is sent, and
///   the buffer is committed when it ends the turn. The clock runs from the
///   end of speech to the gate's end of turn, the server's `committed` and
///   the completed transcript. A commit before the speech ended is a
///   mid-pause cut-off: its row has a negative `speech_end_to_commit_ms`
///   and `commits` above one.
///
/// Every committed buffer counts as a turn. Spend comes from each event's
/// reported `usage` and is appended to a ledger outside the repository;
/// the run stops before a turn that could cross either cap. The API key
/// comes from OPENAI_API_KEY, set at launch from the Keychain
/// (\`security find-generic-password -s com.karanvirkang.jarvis -a openAIAPIKey -w\`);
/// without it the key is read in-process from the Keychain with user
/// interaction disabled, so a permission prompt fails the run instead of
/// appearing. It is never printed or written.
///
/// Off unless JARVIS_LIVE_REALTIME_BENCH=1.
@MainActor
final class RealtimeTurnBenchTests: XCTestCase {
    final class RecordingWire: RealtimeVoiceWire, @unchecked Sendable {
        struct Event { let at: Double; let type: String; let itemID: String?; let usage: JSONValue? }
        private let task: URLSessionWebSocketTask
        private let lock = NSLock()
        private var events: [Event] = []

        init(_ request: URLRequest) {
            task = URLSession.shared.webSocketTask(with: request)
            task.resume()
        }
        func send(_ text: String) async throws { try await task.send(.string(text)) }
        func receive() async throws -> String {
            let message = try await task.receive()
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: text = ""
            }
            let at = ProcessInfo.processInfo.systemUptime
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
                let item = value["item_id"]?.string ?? value["item"]?["id"]?.string
                lock.lock()
                events.append(Event(at: at, type: value["type"]?.string ?? "", itemID: item,
                                    usage: value["usage"] ?? value["response"]?["usage"]))
                lock.unlock()
            }
            return text
        }
        func close() async { task.cancel(with: .goingAway, reason: nil) }

        func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
        func first(_ type: String, after: Double) -> Event? { snapshot().first { $0.type == type && $0.at >= after } }
    }

    /// USD per million tokens. gpt-4o-transcribe bills the input transcript;
    /// a Realtime response would bill at the gpt-realtime rates, but the
    /// bench never asks for one.
    static func dollars(_ usage: JSONValue?, type: String) -> Double {
        guard let usage else { return 0 }
        if usage["type"]?.string == "duration" { return (usage["seconds"]?.benchNumber ?? 0) * 0.006 / 60 }
        let input = usage["input_tokens"]?.benchNumber ?? 0
        let output = usage["output_tokens"]?.benchNumber ?? 0
        let audioIn = usage["input_token_details"]?["audio_tokens"]?.benchNumber ?? input
        let textIn = max(0, input - audioIn)
        if type == "response.done" {
            let audioOut = usage["output_token_details"]?["audio_tokens"]?.benchNumber ?? 0
            return (audioIn * 32 + textIn * 4 + audioOut * 64 + max(0, output - audioOut) * 16) / 1_000_000
        }
        return (audioIn * 6 + textIn * 2.5 + output * 10) / 1_000_000
    }

    struct Ledger {
        let url: URL
        var turns = 0
        var usd = 0.0
        init(_ url: URL) {
            self.url = url
            for line in ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n") {
                guard let row = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                turns += Int(row["turns"]?.benchNumber ?? 0)
                usd += row["usd"]?.benchNumber ?? 0
            }
        }
        mutating func add(turns: Int, usd: Double, note: String) throws {
            self.turns += turns; self.usd += usd
            let row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "turns": turns,
                                      "usd": usd, "total_turns": self.turns, "total_usd": self.usd, "note": note]
            let line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
            } else { try line.write(to: url) }
        }
    }

    static let phrases: [(text: String, pauses: Bool)] = [
        ("open Calculator", false),
        ("click Reply", false),
        ("show names", false),
        ("where is Safari", false),
        ("next desktop", false),
        ("open [[slnc 450]] Calculator", true),
        ("click the [[slnc 500]] Reply button", true),
        ("where did [[slnc 600]] my Safari window go", true),
    ]
    static let voices = ["Samantha", "Daniel", "Karen", "Moira"]

    func testRealtimeTurns() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_LIVE_REALTIME_BENCH"] == "1" else { throw XCTSkip("paid bench: set JARVIS_LIVE_REALTIME_BENCH=1") }
        let mode = env["JARVIS_BENCH_MODE"] ?? "fn"
        let turns = Int(env["JARVIS_BENCH_TURNS"] ?? "") ?? 10
        let label = env["JARVIS_BENCH_LABEL"] ?? "current"
        let maxTurns = Int(env["JARVIS_BENCH_MAX_TURNS"] ?? "") ?? 300
        let maxUSD = Double(env["JARVIS_BENCH_MAX_USD"] ?? "") ?? 5
        let ledgerURL = URL(fileURLWithPath: try XCTUnwrap(env["JARVIS_BENCH_LEDGER"]))
        let out = URL(fileURLWithPath: try XCTUnwrap(env["JARVIS_BENCH_OUT"]))
        let store = KeychainAPIKeyStore(service: env["JARVIS_BENCH_KEY_SERVICE"] ?? "com.karanvirkang.jarvis",
                                        account: "openAIAPIKey", allowUserInteraction: false)
        let key = try XCTUnwrap(env["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? (try store.read()),
                                "no OpenAI key in OPENAI_API_KEY or the Keychain (the Keychain needs JARVIS_LIVE_KEYCHAIN=1)")
        var ledger = Ledger(ledgerURL)

        let wireBox = LockedBox<RecordingWire?>(nil)
        let client = RealtimeVoiceClient(wireFactory: { request in
            let wire = RecordingWire(request)
            wireBox.set(wire)
            return wire
        })
        try await client.connect(apiKey: key, inputMode: mode == "fn" ? .manual : .conversation)
        let wire = try XCTUnwrap(wireBox.value)
        var rows: [[String: Any]] = []
        let chunk = 2_400  // 100 ms at 24 kHz
        let gate = mode == "fn" ? nil : try VoiceActivityGate.silero()
        var commits: [Double] = []

        func stream(_ samples: [Int16]) async throws {
            var next = ProcessInfo.processInfo.systemUptime
            for start in stride(from: 0, to: samples.count, by: chunk) {
                let slice = Array(samples[start..<min(start + chunk, samples.count)])
                let pcm = slice.withUnsafeBytes { Data($0) }
                if let gate {
                    for event in try await gate.admit(pcm) {
                        switch event {
                        case .audio(let data): try await client.sendAudio(data)
                        case .turnEnded:
                            try await client.commitAudio()
                            commits.append(ProcessInfo.processInfo.systemUptime)
                        case .turnStarted: break
                        }
                    }
                } else {
                    try await client.sendAudio(pcm)
                }
                next += Double(slice.count) / 24_000
                let wait = next - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .milliseconds(wait * 1000)) }
            }
        }

        for turn in 0..<turns {
            let perTurnCeiling = 0.02
            guard ledger.turns + 1 <= maxTurns, ledger.usd + perTurnCeiling <= maxUSD else {
                print("realtime bench: stopping at the cap (\(ledger.turns) turns, $\(String(format: "%.4f", ledger.usd)))")
                break
            }
            let phrase = Self.phrases[turn % Self.phrases.count]
            let voice = Self.voices[(turn / Self.phrases.count) % Self.voices.count]
            let speech = try Self.spoken(phrase.text, voice: voice)
            let marker = ProcessInfo.processInfo.systemUptime
            commits = []
            try await stream([Int16](repeating: 0, count: 4_800) + speech)
            let speechEnd = ProcessInfo.processInfo.systemUptime
            var row: [String: Any] = ["v": 1, "kind": "realtime", "label": label, "mode": mode, "turn": turn,
                                      "pauses": phrase.pauses, "voice": voice,
                                      "speech_ms": Double(speech.count) / 24.0]
            if mode == "fn" {
                try await client.commitAudio()
                let committedAt = ProcessInfo.processInfo.systemUptime
                var done: RecordingWire.Event?
                while done == nil, ProcessInfo.processInfo.systemUptime < committedAt + 8 {
                    done = wire.first("conversation.item.input_audio_transcription.completed", after: committedAt)
                    try await Task.sleep(for: .milliseconds(5))
                }
                if let done { row["release_to_transcript_ms"] = (done.at - committedAt) * 1000 }
            } else {
                let tailEnd = ProcessInfo.processInfo.systemUptime + 4
                while commits.last.map({ $0 < speechEnd }) ?? true, ProcessInfo.processInfo.systemUptime < tailEnd {
                    var room = [Int16](repeating: 0, count: chunk)
                    for i in room.indices { room[i] = Int16.random(in: -40...40) }
                    try await stream(room)
                }
                if commits.last.map({ $0 < speechEnd }) ?? true {
                    try await client.commitAudio()
                    commits.append(ProcessInfo.processInfo.systemUptime)
                    row["tail_capped"] = true
                }
                row["commits"] = commits.count
                row["speech_end_to_gate_end_ms"] = (commits[0] - speechEnd) * 1000
                var confirmed: [RecordingWire.Event] = []
                while confirmed.count < commits.count, ProcessInfo.processInfo.systemUptime < commits.last! + 8 {
                    confirmed = wire.snapshot().filter { $0.type == "input_audio_buffer.committed" && $0.at >= marker }
                    try await Task.sleep(for: .milliseconds(5))
                }
                if let first = confirmed.first { row["speech_end_to_commit_ms"] = (first.at - speechEnd) * 1000 }
                var done: RecordingWire.Event?
                if let last = confirmed.last {
                    while done == nil, ProcessInfo.processInfo.systemUptime < last.at + 8 {
                        done = wire.snapshot().first {
                            $0.type == "conversation.item.input_audio_transcription.completed" && $0.itemID == last.itemID
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }
                if let done { row["speech_end_to_transcript_ms"] = (done.at - speechEnd) * 1000 }
            }
            try await Task.sleep(for: .milliseconds(300))
            let spent = wire.snapshot().filter { $0.at >= marker && $0.usage != nil }
                .reduce(0) { $0 + Self.dollars($1.usage, type: $1.type) }
            try ledger.add(turns: max(1, commits.count), usd: spent, note: "\(label) \(mode)")
            row["usd"] = spent
            rows.append(row)
            print("realtime bench \(mode) turn \(turn): \(row.filter { $0.key.hasSuffix("_ms") })")
        }
        client.teardown()
        let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: out) {
            try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
        } else { try Data(text.utf8).write(to: out) }
        print("realtime bench: ledger \(ledger.turns) turns, $\(String(format: "%.4f", ledger.usd))")
    }

    /// The synthetic set: macOS `say` voices at the Realtime input format;
    /// `[[slnc N]]` inserts an N ms pause mid-sentence.
    static func spoken(_ text: String, voice: String) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@24000", text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
}

private extension JSONValue {
    var benchNumber: Double? { if case .number(let v) = self { return v }; return nil }
}

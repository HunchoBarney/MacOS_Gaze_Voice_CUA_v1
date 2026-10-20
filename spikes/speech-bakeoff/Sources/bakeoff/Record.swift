import AVFoundation
import Darwin
import Foundation

/// Accept a corpus clip only after file validation and the speaker's confirmation.
@MainActor
enum Record {
    struct Phrase: Codable { let id: String; let job: String; let prompt: String }
    struct PhrasesDoc: Codable { let phrases: [Phrase] }
    struct Entry: Codable {
        let id: String
        var prompt: String
        var wav: String
        var status: String
        var device: String
        var sample_rate: Double
        var recorded_at: String
        var duration_s: Double
        var peak: Int? // Optional to preserve the original v1 manifest.
        var active_seconds: Double?
        var confirmed: Bool?
    }
    struct Manifest: Codable {
        var recordings: [Entry]
        var device_note: String
    }

    static func run(corpusDir: URL, only: String? = nil) async throws {
        guard isatty(STDIN_FILENO) == 1 else {
            throw BakeoffError.usage("record needs an interactive terminal; use mic-check for an unattended capture")
        }
        let phrasesURL = corpusDir.appendingPathComponent("phrases.json")
        let doc = try JSONDecoder().decode(PhrasesDoc.self, from: Data(contentsOf: phrasesURL))
        let recDir = corpusDir.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        var manifest = try loadManifest(corpusDir: corpusDir)
        guard only == nil || doc.phrases.contains(where: { $0.id == only }) else {
            throw BakeoffError.usage("unknown phrase: \(only ?? "")")
        }
        let targets = doc.phrases.filter { phrase in
            if let only { return phrase.id == only }
            return !manifest.recordings.contains { $0.id == phrase.id && $0.status == "ok" }
        }
        guard !targets.isEmpty else {
            say("All phrases are already recorded. Use --only p01 to redo one.")
            return
        }
        try await MicCapture.requirePermission()
        manifest.device_note = "AVAudioRecorder native 48 kHz PCM; offline conversion to 16 kHz mono"
        say("Recording \(targets.count) remaining phrase(s). Enter starts; recording stops automatically.")
        say("Speak only after REC appears. Enter keeps the clip; p plays it; r retries; q saves progress and quits.")
        for phrase in targets {
            var accepted = false
            while !accepted {
                let seconds = captureSeconds(for: phrase.prompt)
                say("\n\(phrase.id) [\(phrase.job)] - \(Int(seconds)) second window")
                say("  Say: \"\(phrase.prompt)\"")
                say("  Enter when ready, or q to quit: ", newline: false)
                guard let answer = readLine(), answer.lowercased() != "q" else { return }
                // Keypresses during capture must not arm or accept the next clip.
                tcflush(STDIN_FILENO, TCIFLUSH)
                let clip = try await MicCapture.capture(directory: recDir, seconds: seconds)
                tcflush(STDIN_FILENO, TCIFLUSH)
                say("  Saved \(String(format: "%.2f", clip.duration))s; peak \(Int(clip.peakDB)) dB; \(clip.quality).")
                guard clip.quality == "ok" else {
                    say("  Too quiet to accept. Check Sound > Input or move closer, then retry.")
                    continue
                }
                while !accepted {
                    say("  Finished the phrase correctly? Enter=keep, p=listen, r=retry, q=quit: ", newline: false)
                    guard let decision = readLine() else { return }
                    switch decision.lowercased() {
                    case "":
                        upsert(&manifest, Entry(
                            id: phrase.id, prompt: phrase.prompt, wav: "recordings/\(clip.url.lastPathComponent)",
                            status: "ok", device: clip.device, sample_rate: Audio.sampleRate,
                            recorded_at: ISO8601DateFormatter().string(from: Date()), duration_s: clip.duration,
                            peak: Int(clip.peakDB), active_seconds: clip.activeSeconds, confirmed: true))
                        try save(manifest, corpusDir: corpusDir)
                        accepted = true
                    case "p":
                        let player = try AVAudioPlayer(contentsOf: clip.url)
                        guard player.play() else { throw BakeoffError.audio("could not play the recorded file") }
                        while player.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
                    case "r":
                        break
                    case "q":
                        return
                    default:
                        continue
                    }
                    if decision.lowercased() == "r" { break }
                }
            }
        }
        let ok = manifest.recordings.filter { $0.status == "ok" }.count
        say("\nDone: \(ok)/\(doc.phrases.count) usable clips. Progress is saved after every kept clip.")
    }

    static func captureSeconds(for prompt: String) -> Double {
        max(6, ceil(Double(prompt.split(separator: " ").count) / 2 + 3))
    }

    static func say(_ message: String, newline: Bool = true) {
        print(message, terminator: newline ? "\n" : "")
        fflush(stdout)
    }

    static func loadManifest(corpusDir: URL) throws -> Manifest {
        let url = corpusDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Manifest(recordings: [], device_note: "")
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private static func upsert(_ m: inout Manifest, _ e: Entry) {
        if let i = m.recordings.firstIndex(where: { $0.id == e.id }) {
            m.recordings[i] = e
        } else {
            m.recordings.append(e)
        }
    }

    static func save(_ m: Manifest, corpusDir: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: corpusDir.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

import Foundation

/// speech-bakeoff — P2d spike CLI.
/// Commands:
///   bakeoff record                       — interactive phrase recorder (human step)
///   bakeoff mic-check                    — verify a 3-second microphone file
///   bakeoff setup-corpus                 — copy library wavs from the FluidAudio checkout
///   bakeoff inventory                    — probe engines/locales/models, no audio
///   bakeoff feed --engine E --clip C --iters N [--fast]
///                                        — run corpus through an engine
///   bakeoff report                       — regenerate results/REPORT.md
public enum Bakeoff {
    public static func main() async {
        do {
            try await execute()
        } catch {
            FileHandle.standardError.write(Data("bakeoff: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func execute() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            throw BakeoffError.usage("record | mic-check | setup-corpus | inventory | feed | report")
        }
        args.removeFirst()
        let corpusDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus")

        switch cmd {
        case "record":
            var only: String?
            var i = 0
            while i < args.count {
                guard args[i] == "--only", i + 1 < args.count, only == nil else {
                    throw BakeoffError.usage("record [--only p01]")
                }
                only = args[i + 1]
                i += 2
            }
            try await Record.run(corpusDir: corpusDir, only: only)

        case "mic-check":
            guard args.isEmpty else { throw BakeoffError.usage("mic-check takes no arguments") }
            Record.say("Recording a 3-second microphone diagnostic (not added to your corpus).")
            let clip = try await MicCapture.capture(
                directory: corpusDir.appendingPathComponent("recordings/diagnostics"), seconds: 3)
            Record.say("File verified: \(String(format: "%.2f", clip.duration))s, peak \(Int(clip.peakDB)) dB, \(clip.quality).")
            Record.say("Local file: \(clip.url.path)")

        case "setup-corpus":
            try setupCorpus(corpusDir: corpusDir)

        case "inventory":
            try await inventory()

        case "measure":
            var engine: String?
            var clip: String?
            var output: String?
            var iterations = 3
            var i = 0
            while i < args.count {
                guard i + 1 < args.count else { throw BakeoffError.usage("measure flag needs a value") }
                switch args[i] {
                case "--engine": engine = args[i + 1]
                case "--clip": clip = args[i + 1]
                case "--out": output = args[i + 1]
                case "--iters":
                    guard let count = Int(args[i + 1]), count > 0 else {
                        throw BakeoffError.usage("measure --iters must be positive")
                    }
                    iterations = count
                default: throw BakeoffError.usage("measure --engine NAME --out FILE [--iters 3] [--clip p01]")
                }
                i += 2
            }
            guard let engine, let output else { throw BakeoffError.usage("measure requires --engine and --out") }
            try await Measure.run(
                engine: engine, iters: iterations, clip: clip, output: URL(fileURLWithPath: output))

        case "feed":
            var engine = "all", clip: String?, iters = 3, fast = false
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--engine": i += 1; engine = args[i]
                case "--clip": i += 1; clip = args[i]
                case "--iters": i += 1; iters = Int(args[i]) ?? 3
                case "--fast": fast = true
                default: throw BakeoffError.usage("feed --engine X --clip Y --iters N [--fast]")
                }
                i += 1
            }
            try await Run.feed(engineArg: engine, clipArg: clip, iters: iters, fast: fast)

        case "report":
            try Report.generate(resultsPath: "spikes/speech-bakeoff/results/results.json",
                                outPath: "spikes/speech-bakeoff/results/REPORT.md")

        default:
            throw BakeoffError.usage("unknown command \(cmd)")
        }
    }

    /// Copy the 3 FluidAudio fixture wavs into corpus/library/ (gitignored).
    static func setupCorpus(corpusDir: URL) throws {
        let src = URL(fileURLWithPath: ".build/checkouts/FluidAudio/Tests/FluidAudioTests/ASR/Parakeet/SlidingWindow/Fixtures")
        let dst = corpusDir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let map = ["01-validation-request-21.4s.wav": "lib01.wav",
                   "02-release-readiness-19.8s.wav": "lib02.wav",
                   "03-diff-explanation-16.9s.wav": "lib03.wav"]
        for (from, to) in map {
            let s = src.appendingPathComponent(from)
            let d = dst.appendingPathComponent(to)
            guard FileManager.default.fileExists(atPath: s.path) else {
                print("missing \(from) — FluidAudio checkout not at .build/checkouts (run `swift build` in the app first)")
                continue
            }
            if !FileManager.default.fileExists(atPath: d.path) {
                try FileManager.default.copyItem(at: s, to: d)
            }
            print("\(to) ready")
        }
    }

    /// Engine/environment probe — no audio processed.
    static func inventory() async throws {
        var doc = Run.loadDoc()
        doc.probe["date"] = ISO8601DateFormatter().string(from: Date())
        doc.probe["fluidaudio_pin"] = "0.17.5"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JevVoice/Models")
        doc.probe["parakeet_models_root"] = root.path
        doc.probe["parakeet_models_bytes"] = String(Run.dirBytes(root))
        if #available(macOS 26.0, *) {
            let drv = SpeechDriver()
            let (_, _, note) = await drv.probe()
            doc.probe["speech_locale"] = note
        } else {
            doc.probe["speech_locale"] = "macOS<26 — unavailable"
        }
        doc.probe["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        Run.saveDoc(doc)
        print(doc.probe.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }
}

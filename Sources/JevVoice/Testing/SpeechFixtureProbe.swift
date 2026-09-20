#if SPEECH_FIXTURE_PROBE
import AppKit
import AVFoundation
import Speech
import JevVoiceCore

/// Opt-in development build only. Feeds disposable audio into the same local
/// recognition request without capturing a microphone. Native execution requires
/// the separate visible workflow window and its explicit Run button.
@MainActor
enum SpeechFixtureProbe {
    static func run(input: URL, output: URL, executeNative: Bool = false) async {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: output) else { return }
        defer { try? log.close() }
        let started = ProcessInfo.processInfo.systemUptime
        func record(_ fields: [String: Any]) {
            var fields = fields
            fields["elapsed"] = ProcessInfo.processInfo.systemUptime - started
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
                try? log.write(contentsOf: data + Data([10]))
            }
        }
        record(["authorization": SFSpeechRecognizer.authorizationStatus().rawValue, "native": executeNative, "accessibility": AXIsProcessTrusted()])
        let suite = "jev.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = Config(defaults: defaults, keyStore: FixtureKeyStore(), environment: [:])
        let capture = FixtureCapture()
        let apps = InstalledApps.all()
        let interpreter = CommandInterpreter(client: JevClient(apiKey: "", baseURL: URL(fileURLWithPath: "/dev/null")), installedApps: apps)
        let dryRun: ((Decision) async throws -> String)? = executeNative ? nil : { decision in
            record(["wouldDispatch": decision.action.rawValue, "target": decision.targetApp ?? "", "text": decision.text ?? ""])
            return "Simulated action"
        }
        let dryDictation: ((Decision) async throws -> Bool)? = executeNative ? nil : { decision in
            record(["wouldUpdateText": decision.text ?? "", "target": decision.targetApp ?? ""])
            return true
        }
        let controller = VoiceController(config: config, speech: capture, authorize: { true },
            interpret: { try await interpreter.interpret(transcript: $0, frontmostApp: $1) }, execute: dryRun,
            installedApps: apps, updateDictation: dryDictation)
        controller.begin()
        for _ in 0..<20 { await Task.yield() }
        var transcript = SpeechTranscriptAccumulator()
        do {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return }
            let request = try SpeechRecognizer.makeRecognitionRequest(supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)
            let file = try AVAudioFile(forReading: input)
            var finished = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    if let result {
                        let assembled = SpeechRecognizer.accumulate(result, into: &transcript)
                        capture.emit(result.isFinal ? .final(assembled) : .partial(assembled))
                        record(["assembled": assembled, "controller": String(describing: controller.status),"text": result.bestTranscription.formattedString,
                                "final": result.isFinal,
                                "metadata": result.speechRecognitionMetadata != nil,
                                "segments": result.bestTranscription.segments.map {
                                    ["text": $0.substring, "start": $0.timestamp, "duration": $0.duration, "confidence": $0.confidence] as [String: Any]
                                }])
                        if result.isFinal { finished = true }
                    }
                    if let error { record(["error": error.localizedDescription]); finished = true }
                }
            }
            while file.framePosition < file.length, !finished {
                let count = AVAudioFrameCount(min(1024, file.length - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
                try file.read(into: buffer, frameCount: count)
                request.append(buffer)
                try await Task.sleep(nanoseconds: UInt64(Double(count) / file.processingFormat.sampleRate * 1e9))
            }
            record(["inputEnded": true])
            controller.finish()
            request.endAudio(); task.finish()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !finished, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            for _ in 0..<100 {
                if controller.canBegin { break }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            record(["outcome": String(describing: controller.status), "result": controller.resultMessage,
                "timings": controller.measurements, "transcript": controller.transcript,
                "decisions": controller.history.map { $0.displaySummary }])
            await controller.shutdown()
            task.cancel()
        } catch { record(["error": error.localizedDescription]) }
    }
}
private struct FixtureKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ apiKey: String) throws { }
    func delete() throws { }
}
@MainActor
private final class FixtureCapture: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    var session: UUID?
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String { self.session = session; return "Prerecorded test fixture" }
    func finish() { }
    func cancel() { session = nil }
    func emit(_ event: SpeechEvent) { if let session { onEvent?(session, event) } }
}

/// Visible, manually triggered native integration test. Absent from normal builds.
@MainActor
final class SpeechFixtureWindow: NSObject {
    private let window: NSWindow
    private let input: URL
    private let output: URL
    private let button = NSButton(title: "Run disposable workflow", target: nil, action: #selector(run))
    private let label = NSTextField(labelWithString: "Prerecorded speech → normal command execution. No microphone capture.")
    private var task: Task<Void, Never>?
    init(input: URL, output: URL) {
        self.input = input; self.output = output
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 150),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Jev Voice — Disposable Workflow Test"
        window.isReleasedWhenClosed = false
        label.frame = NSRect(x: 20, y: 95, width: 510, height: 35)
        button.frame = NSRect(x: 20, y: 35, width: 260, height: 35)
        button.target = self
        window.contentView?.addSubview(label); window.contentView?.addSubview(button)
        NSApp.setActivationPolicy(.regular)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func run() {
        guard task == nil else { return }
        button.isEnabled = false; label.stringValue = "Running disposable voice workflow…"
        task = Task {
            await SpeechFixtureProbe.run(input: input, output: output, executeNative: true)
            label.stringValue = "Test ended. Inspect the target app and the recorded outcome."
            button.isEnabled = true; task = nil
        }
    }
}
#endif

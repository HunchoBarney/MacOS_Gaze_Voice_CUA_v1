import CoreML
import CryptoKit
import FluidAudio
import Foundation

struct ConversationAudioTimeline: Sendable {
    private(set) var retained = 0..<0
    private(set) var activeStart: Int?
    private let maximumSamples: Int
    private let idleSamples: Int

    init(maximumSamples: Int = LocalTranscriber.maximumCaptureSamples, idleSamples: Int = 16_000) {
        self.maximumSamples = maximumSamples
        self.idleSamples = idleSamples
    }

    mutating func append(_ count: Int) throws {
        guard count > 0, retained.upperBound <= Int.max - count else { throw LocalSpeechError.captureLoss }
        let end = retained.upperBound + count
        let start = activeStart == nil ? max(retained.lowerBound, end - idleSamples) : retained.lowerBound
        guard end - start <= maximumSamples else { throw LocalSpeechError.captureLoss }
        retained = start..<end
    }

    mutating func beginSpeech(at sample: Int) throws {
        guard activeStart == nil, sample >= 0, sample <= retained.upperBound, !retained.isEmpty else {
            throw LocalSpeechError.captureLoss
        }
        activeStart = retained.lowerBound
    }

    mutating func seal(at sample: Int) throws -> Range<Int> {
        guard let start = activeStart, sample > start, sample <= retained.upperBound else {
            throw LocalSpeechError.captureLoss
        }
        activeStart = nil
        retained = sample..<retained.upperBound
        return start..<sample
    }
}

actor ConversationCapture {
    struct Utterance: Sendable {
        let session: UUID
        let id: UUID
        let samples: [Float]
        let range: Range<Int>
        let detectedAt: TimeInterval
        let sealedAt: TimeInterval
    }

    enum Event: Sendable {
        case began(session: UUID, id: UUID, sample: Int, detectedAt: TimeInterval)
        case utterance(Utterance)
    }

    private struct Resource: Decodable {
        let schema: Int
        let repository: String
        let revision: String
        let model: String
        let files: [String: String]
    }
    private enum ResourceFailure: Error, LocalizedError {
        case manifest, metadata, path, member(String), inventory(Set<String>, Set<String>)
        var errorDescription: String? { "The bundled voice model is missing or damaged. Please reinstall Jev Voice." }
    }

    private let modelDirectory: URL?
    private var vad: VadManager?
    private var preparation: Task<VadManager, Error>?
    private nonisolated let ready = LockedBox(false)
    private var session: UUID?
    private var events: AsyncThrowingStream<Event, Error>.Continuation?
    private var converter = AudioConverter()
    private var vadState = VadStreamState.initial()
    private var timeline = ConversationAudioTimeline()
    private var pending: [Float] = []
    private var bank: [Float] = []
    private var bankStart = 0
    private var current: (id: UUID, detectedAt: TimeInterval)?
    private var outstanding: [UUID: Int] = [:]
    private var consuming = false
    private let segmentation = VadSegmentationConfig(minSpeechDuration: 0.15,
        minSilenceDuration: 0.25, maxSpeechDuration: 60, speechPadding: 0.1)

    init(modelDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("ConversationVAD")) {
        self.modelDirectory = modelDirectory
    }

    nonisolated var prepared: Bool { ready.value }

    func prepare() async throws {
        if vad != nil { return }
        if let preparation {
            vad = try await preparation.value
            ready.set(true)
            return
        }
        guard let modelDirectory else { throw LocalSpeechError.unavailable }
        let task = Task.detached(priority: .userInitiated) {
            let modelURL = try Self.verifiedModel(in: modelDirectory)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            return VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
        }
        preparation = task
        do {
            vad = try await task.value
            ready.set(true)
            preparation = nil
        } catch {
            preparation = nil
            ready.set(false)
            throw error
        }
    }

    private static func verifiedModel(in directory: URL) throws -> URL {
        let root = directory.resolvingSymlinksInPath()
        let manifest = root.appendingPathComponent("resource.json")
        let bytes = try Data(contentsOf: manifest)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == "be41b15f2b6c5c73c4824b99963b54bc6d5f58c3af04468132ddfe131c1c8062" else {
            throw ResourceFailure.manifest
        }
        let resource = try JSONDecoder().decode(Resource.self, from: bytes)
        guard resource.schema == 1, resource.repository == "FluidInference/silero-vad-coreml",
              resource.revision.count == 40, resource.revision.allSatisfy(\.isHexDigit),
              resource.model.hasSuffix(".mlmodelc"), !resource.files.isEmpty else {
            throw ResourceFailure.metadata
        }
        func resolved(_ path: String) throws -> URL {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw ResourceFailure.path
            }
            let result = root.appendingPathComponent(path).resolvingSymlinksInPath()
            guard result.path.hasPrefix(root.path + "/") else { throw ResourceFailure.path }
            return result
        }
        for (path, expected) in resource.files {
            let data = try Data(contentsOf: resolved(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw ResourceFailure.member(path) }
        }
        let model = try resolved(resource.model)
        guard let entries = FileManager.default.enumerator(at: model,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw LocalSpeechError.unavailable
        }
        var members = Set<String>()
        for case let file as URL in entries {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let normalized = file.resolvingSymlinksInPath().path
            guard normalized.hasPrefix(root.path + "/") else { throw ResourceFailure.path }
            members.insert(String(normalized.dropFirst(root.path.count + 1)))
        }
        let expectedMembers = Set(resource.files.keys.filter { $0.hasPrefix(resource.model + "/") })
        guard !members.isEmpty, members == expectedMembers else { throw ResourceFailure.inventory(members, expectedMembers) }
        return model
    }

    func begin(session id: UUID) throws -> AsyncThrowingStream<Event, Error> {
        guard vad != nil else { throw LocalSpeechError.unavailable }
        if let session { stop(session: session) }
        session = id
        converter = AudioConverter()
        vadState = .initial()
        timeline = ConversationAudioTimeline()
        pending = []; bank = []; bankStart = 0; current = nil
        outstanding = [:]; consuming = false
        let pair = AsyncThrowingStream<Event, Error>.makeStream()
        events = pair.continuation
        return pair.stream
    }

    func consume(_ frame: VoicePCMFrame, session id: UUID) async throws {
        guard session == id, let vad else { throw LocalSpeechError.stale }
        guard !consuming else { throw LocalSpeechError.captureLoss }
        consuming = true
        defer { if session == id { consuming = false } }
        let samples = try converter.resampleBuffer(frame.buffer())
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite),
              pending.count + samples.count <= LocalTranscriber.maximumCaptureSamples else {
            throw LocalSpeechError.captureLoss
        }
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= VadManager.chunkSize {
            let chunk = Array(pending[offset..<(offset + VadManager.chunkSize)])
            offset += VadManager.chunkSize
            try timeline.append(chunk.count)
            bank.append(contentsOf: chunk)
            trimBank()
            let observed = try await vad.processStreamingChunk(chunk, state: vadState, config: segmentation)
            guard session == id, !Task.isCancelled else { throw LocalSpeechError.stale }
            guard observed.probability.isFinite, (0...1).contains(observed.probability) else {
                throw LocalSpeechError.captureLoss
            }
            vadState = observed.state
            guard let event = observed.event else { continue }
            if event.isStart {
                try timeline.beginSpeech(at: event.sampleIndex)
                let turn = UUID(), detectedAt = ProcessInfo.processInfo.systemUptime
                current = (turn, detectedAt)
                try emit(.began(session: id, id: turn, sample: event.sampleIndex, detectedAt: detectedAt))
            } else {
                guard let current else { throw LocalSpeechError.captureLoss }
                let range = try timeline.seal(at: event.sampleIndex)
                guard range.lowerBound >= bankStart, range.upperBound - bankStart <= bank.count else {
                    throw LocalSpeechError.captureLoss
                }
                let sealed = Array(bank[(range.lowerBound - bankStart)..<(range.upperBound - bankStart)])
                guard outstanding.values.reduce(0, +) + sealed.count <= 2 * LocalTranscriber.maximumCaptureSamples else {
                    throw LocalSpeechError.captureLoss
                }
                outstanding[current.id] = sealed.count
                try emit(.utterance(.init(session: id, id: current.id, samples: sealed, range: range,
                    detectedAt: current.detectedAt, sealedAt: ProcessInfo.processInfo.systemUptime)))
                self.current = nil
                trimBank()
            }
        }
        pending.removeFirst(offset)
    }

    private func trimBank() {
        let drop = timeline.retained.lowerBound - bankStart
        guard drop > 0 else { return }
        bank.removeFirst(drop)
        bankStart = timeline.retained.lowerBound
    }

    private func emit(_ event: Event) throws {
        guard let events else { throw LocalSpeechError.stale }
        if case .terminated = events.yield(event) { throw LocalSpeechError.stale }
    }

    func acknowledge(_ utterance: Utterance) {
        guard session == utterance.session else { return }
        outstanding.removeValue(forKey: utterance.id)
    }

    func stop(session id: UUID) {
        guard session == id else { return }
        session = nil
        events?.finish()
        events = nil
        pending = []; bank = []; outstanding = [:]; current = nil
    }
}

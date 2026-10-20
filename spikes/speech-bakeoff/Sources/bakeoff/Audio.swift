@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Audio utilities for the bake-off: wav IO, 16 kHz mono Float32 access,
/// 160 ms chunking (matches Parakeet `.ms160` cadence), mic recording.
enum Audio {
    static let sampleRate: Double = 16_000
    static let chunkSamples = 2560 // 160 ms @ 16 kHz

    /// Load a wav file and return mono Float32 samples at 16 kHz.
    /// Conversion via AVAudioConverter when the file isn't already 16k mono.
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw BakeoffError.audio("cannot allocate buffer for \(url.lastPathComponent)")
        }
        try file.read(into: srcBuf)
        let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate, channels: 1, interleaved: false)!
        if srcFormat == dstFormat, let ch = srcBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(srcBuf.frameLength)))
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw BakeoffError.audio("no converter \(srcFormat) -> \(dstFormat)")
        }
        let ratio = sampleRate / srcFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCap) else {
            throw BakeoffError.audio("cannot allocate conversion buffer")
        }
        let fed = Mutex(false)
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            let first = fed.withLock { value in defer { value = true }; return !value }
            if !first { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return srcBuf
        }
        if let convErr { throw BakeoffError.audio("convert failed: \(convErr)") }
        guard let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Wrap Float32 samples in an AVAudioPCMBuffer (16 kHz mono).
    static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw BakeoffError.audio("buffer alloc failed")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                ch[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buf
    }

    /// Wrap samples in an Int16 PCM buffer — SpeechAnalyzer's
    /// bestAvailableAudioFormat is 16 kHz mono Int16; feeding Float32
    /// traps (verified: SIGTRAP inside Speech.framework).
    static func bufferInt16(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw BakeoffError.audio("int16 buffer alloc failed")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.int16ChannelData {
            for i in 0 ..< samples.count {
                ch[0][i] = Int16(max(-1, min(1, samples[i])) * 32767)
            }
        }
        return buf
    }

    /// Split samples into 160 ms frames (last frame zero-padded or short).
    static func chunks(_ samples: [Float]) -> [[Float]] {
        stride(from: 0, to: samples.count, by: chunkSamples).map {
            Array(samples[$0 ..< min($0 + chunkSamples, samples.count)])
        }
    }

    /// Write mono Float32 samples to a 16-bit PCM wav.
    static func writeWav(_ samples: [Float], to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let buf = try buffer(samples)
        try file.write(from: buf)
        _ = fmt
    }
}

enum BakeoffError: Error, CustomStringConvertible {
    case audio(String), engine(String), usage(String)
    var description: String {
        switch self {
        case .audio(let m): return "audio: \(m)"
        case .engine(let m): return "engine: \(m)"
        case .usage(let m): return "usage: \(m)"
        }
    }
}

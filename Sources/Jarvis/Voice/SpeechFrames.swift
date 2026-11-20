import AVFoundation
import Foundation
import JarvisCore

enum LocalSpeechError: Error, LocalizedError {
    case unavailable, busy, stale, captureLoss, tooShort, emptyFinal, deadline
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech recognition is unavailable right now."
        case .busy: return "The previous speech turn is still finishing. Please try again."
        case .stale: return "That speech turn was cancelled."
        case .captureLoss: return "Some speech audio was lost. No command was submitted."
        case .tooShort: return "The recording was too short to recognize safely."
        case .emptyFinal: return "I could not recognize that recording. No command was submitted."
        case .deadline: return "Speech finalization took too long. No command was submitted."
        }
    }
}

/// Copy native buffers before leaving the tap lifetime; no unchecked buffer sharing.
struct VoicePCMFrame: Sendable {
    let bytes: Data
    let sampleRate: Double
    let isFloat: Bool
    let frames: Int

    init(samples: [Float], sampleRate: Double = 16_000) throws {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else { throw LocalSpeechError.captureLoss }
        bytes = samples.withUnsafeBytes { Data($0) }
        self.sampleRate = sampleRate
        isFloat = true
        frames = samples.count
    }

    init(copying buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.channelCount == 1, buffer.frameLength > 0,
              buffer.frameLength <= 65_536, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0 else { throw LocalSpeechError.captureLoss }
        frames = Int(buffer.frameLength); sampleRate = buffer.format.sampleRate
        if buffer.format.commonFormat == .pcmFormatInt16, let source = buffer.int16ChannelData?[0] {
            isFloat = false; bytes = Data(bytes: source, count: frames * MemoryLayout<Int16>.size)
        } else if buffer.format.commonFormat == .pcmFormatFloat32, let source = buffer.floatChannelData?[0] {
            isFloat = true; bytes = Data(bytes: source, count: frames * MemoryLayout<Float>.size)
        } else { throw LocalSpeechError.captureLoss }
    }

    func buffer() throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt16,
                                        sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw LocalSpeechError.captureLoss
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if isFloat, let target = buffer.floatChannelData?[0] {
            _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: target, count: bytes.count))
        } else if let target = buffer.int16ChannelData?[0] {
            _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: target, count: bytes.count))
        } else { throw LocalSpeechError.captureLoss }
        return buffer
    }
}

struct VoiceSpeechDiagnostic: Sendable {
    let turn: UUID
    let stage: String
    var monotonic = ProcessInfo.processInfo.systemUptime
    var metrics: [String: Double] = [:]
}

import CoreAudio
import Foundation

/// Whether another app is capturing audio right now: a call, a recording,
/// dictation. Core Audio lists each audio client as a process object with
/// its input state (macOS 14.2+); Jarvis's own process is left out.
enum OtherMicrophoneUse {
    static func active() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }
        let own = getpid()
        return processes.contains { process in
            guard let pid: pid_t = value(process, kAudioProcessPropertyPID), pid != own else { return false }
            let running: UInt32? = value(process, kAudioProcessPropertyIsRunningInput)
            return running == 1
        }
    }

    private static func value<T: BinaryInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }
}

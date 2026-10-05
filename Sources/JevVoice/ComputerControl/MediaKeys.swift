import AppKit
import Foundation
import OSLog

/// System media/system keys posted as NX_SYSDEFINED events through the HID
/// event tap — the same route the hardware keys take. No app or window is
/// resolved: these are global, and macOS shows its own HUD as the visible
/// effect, which is why callers report delivery rather than an outcome.
enum MediaKeys {
    /// IOKit `ev_keymap.h` aux-key types, carried in the event's data1.
    enum Key: Int, Sendable {
        case volumeUp = 0        // NX_KEYTYPE_SOUND_UP
        case volumeDown = 1      // NX_KEYTYPE_SOUND_DOWN
        case brightnessUp = 2    // NX_KEYTYPE_BRIGHTNESS_UP
        case brightnessDown = 3  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case mute = 7            // NX_KEYTYPE_MUTE
        case playPause = 16      // NX_KEYTYPE_PLAY
        case nextTrack = 17      // NX_KEYTYPE_NEXT
        case previousTrack = 18  // NX_KEYTYPE_PREVIOUS
    }

    /// Why the last production post refused — the Bool seam can only report
    /// refusal; this names the reason for diagnostics.
    enum Refusal: String, Sendable {
        /// macOS is not letting this process synthesize events — without
        /// the preflight the post is silently dropped at the HID tap and
        /// the caller would report a delivery that never happened.
        case postAccessDenied
        /// The NX event objects could not be created.
        case eventCreation
    }

    /// Posting seam (HID tap in production, stub in tests).
    static var poster: (Key) -> Bool = { key in postPair(key) }

    /// The refusal of the last production post; nil after a success.
    /// Stubbed posters never touch it.
    static var refusal: Refusal? { state.refusal }

    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "media-keys")
    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var granted = false
        private var last: Refusal?
        var refusal: Refusal? { lock.lock(); defer { lock.unlock() }; return last }
        /// Only a grant is cached — TCC revocation requires a restart
        /// anyway — while a denial is rechecked each press so access the
        /// user grants mid-run takes effect on the next key.
        var postAccessGranted: Bool {
            lock.lock()
            defer { lock.unlock() }
            if !granted { granted = CGPreflightPostEventAccess() }
            return granted
        }
        func set(_ refusal: Refusal?) { lock.lock(); last = refusal; lock.unlock() }
    }

    /// Post the key-down/key-up pair through the seam. Returns false when
    /// the event objects cannot be created or macOS denies event-synthesis
    /// access (`refusal` says which). The press path is synchronous end to
    /// end — one cached preflight, two event constructions, two CGEvent
    /// posts; no awaits, no queue hops — so delivery latency stays well
    /// inside the media-key budget.
    @discardableResult
    static func post(_ key: Key) -> Bool {
        poster(key)
    }

    /// The data1 packing: NX key type in the high half, pressed state in
    /// the flags nibble — 0xA00 is down, 0xB00 is up.
    static func data1(_ key: Key, down: Bool) -> Int {
        (key.rawValue << 16) | (down ? 0xA00 : 0xB00)
    }

    /// A systemDefined event bridged to CGEvent: subtype 8 is
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS, matching the encoding IOHID delivers
    /// for the hardware keys. Both halves of the pair are always sent —
    /// apps drop a media press that never sees its key-up.
    private static func postPair(_ key: Key) -> Bool {
        guard state.postAccessGranted else {
            state.set(.postAccessDenied)
            log.error("Media key \(key.rawValue) refused: macOS denies this process event-posting access (Privacy & Security).")
            return false
        }
        func event(down: Bool) -> CGEvent? {
            let flags = down ? 0xA00 : 0xB00
            return NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: data1(key, down: down), data2: -1)?.cgEvent
        }
        guard let press = event(down: true), let release = event(down: false) else {
            state.set(.eventCreation)
            return false
        }
        press.post(tap: .cghidEventTap)
        release.post(tap: .cghidEventTap)
        state.set(nil)
        return true
    }
}

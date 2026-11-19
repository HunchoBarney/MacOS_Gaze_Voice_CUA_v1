import AppKit
import OSLog

struct HandsFreeMenuState: Equatable {
    enum Toggle: String { case pause = "Pause Hands-Free", resume = "Resume Hands-Free" }
    let symbol: String
    let label: String
    let detail: String
    let toggle: Toggle?
    let stoppable: Bool
    let pending: Int
    var accessibilityValue: String { label + (pending > 0 ? ", \(pending) pending" : "") }

    init(state: ConversationListeningState, enabled: Bool, label: String, detail: String = "", userPaused: Bool,
         controlsAvailable: Bool, canResume: Bool, stoppable: Bool, pending: Int) {
        self.stoppable = stoppable
        self.pending = pending
        self.label = enabled ? label : "Hands-free off"
        self.detail = detail
        switch enabled ? state : .off {
        case .off: symbol = "mic.slash"; toggle = nil
        case .preparing: symbol = "ellipsis.circle"; toggle = controlsAvailable ? .pause : nil
        case .listening: symbol = "waveform.circle.fill"; toggle = controlsAvailable ? .pause : nil
        case .paused: symbol = "pause.circle"; toggle = userPaused && controlsAvailable && canResume ? .resume : nil
        case .unavailable: symbol = "exclamationmark.circle"; toggle = nil
        }
    }
}

enum VoiceInstanceLock {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "AppDelegate")
    static func acquire() -> FileHandle? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("no Application Support directory — can't establish the instance lock; refusing to run unlocked")
            exit(1)
        }
        // App support is "JevVoice" everywhere else (tracker.log, the
        // EyeTracking symlink) — the lock joins it. The old spaced
        // "Jev Voice" directory is orphaned harmlessly; nothing but this
        // flock file ever lived in it, so there's no migration.
        let dir = support.appendingPathComponent("JevVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let directory = open(dir.path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            log.error("can't open the instance lock directory")
            exit(1)
        }
        defer { close(directory) }
        let fd = openat(directory, "instance.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            if fd >= 0 { close(fd) }
            log.error("can't establish the instance lock")
            exit(1)
        }
        let locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        if locked { return FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
        close(fd)
        return nil
    }
}

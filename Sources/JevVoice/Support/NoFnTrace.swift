import Foundation
import OSLog

enum NoFnTrace {
    enum Stage: String, CaseIterable {
        case preparing, sessionReady, feedOpen, firstAppend, senderStopped, unavailable, wireStart, competingSession
        case vadStart, onsetWindow, onsetNoWindow, vadStop, commit, final, failedFinal, expired
        case admissionRejected, localType, otherAdmission, scopeChanged, semanticUnavailable, semanticEntered
        case executionEntered, executionRejected, workCreated, fieldBound, fieldMissing, nativeAttempt
        case driverAttempt, nativeExact, driverExact, unverified, competingTurn
    }
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "no-fn-boundary")
    private static let lock = NSLock()
    enum Entry { case off, record, refuse }
    static let entry: Entry = {
#if JEV_C1_VOICE_BADGE_ONLY
        return .off
#else
        let env = ProcessInfo.processInfo.environment
        let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard env["JARVIS_C1_NO_FN_TRACE"] != nil || args.contains("--c1-no-fn-trace") else { return .off }
        guard env["JARVIS_C1_NO_FN_TRACE"] == "1", args == ["--c1-no-fn-trace"],
              !env.keys.contains(where: { $0.hasPrefix("JARVIS_") && $0 != "JARVIS_C1_NO_FN_TRACE" }) else { return .refuse }
        return .record
#endif
    }()
    private static var began: ContinuousClock.Instant?
    private static var firstTurn: UUID?
    private static var seen = Set<Stage>()
    private static var stopped = false
    private static var request: UUID?

    static func begin(_ id: UUID) {
        guard entry == .record else { return }
        lock.withLock {
            guard !stopped else { return }
            if let request, request != id {
                stopped = true
                log.notice("boundary=competingSession")
                return
            }
            request = id
            began = .now
        }
    }

    static func mark(_ stage: Stage, turn: UUID? = nil) {
        guard entry == .record else { return }
        lock.withLock {
            guard !stopped else { return }
            let now = ContinuousClock.now
            guard request != nil else { return }
            guard let began, now < began.advanced(by: .seconds(90)) else { stopped = true; return }
            if stage == .vadStart {
                guard let turn else { return }
                if let firstTurn, firstTurn != turn {
                    stopped = true
                    log.notice("boundary=competingTurn")
                    return
                }
                firstTurn = turn
            }
            if let turn, firstTurn != turn { return }
            if turn == nil {
                switch stage {
                case .preparing, .sessionReady, .feedOpen, .firstAppend, .senderStopped, .unavailable, .wireStart: break
                case .semanticUnavailable, .semanticEntered: guard firstTurn != nil else { return }
                default: return
                }
            }
            guard seen.insert(stage).inserted else { return }
            log.notice("boundary=\(stage.rawValue, privacy: .public)")
        }
    }
}

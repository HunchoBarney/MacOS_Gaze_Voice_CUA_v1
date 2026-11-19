import Foundation

/// Observations only. No free-text payload or driver arguments can be stored.
@MainActor
final class VoiceCommandTrace {
    enum Stage: String, Codable, Sendable {
        case contextBegin, contextEnd
        case admissionLocal, admissionRemote, admissionClarify, admissionRefuse, admissionDictation
        case ungroundedTarget, changedTarget, ambiguousAsk
        case localBegin, localEnd, coordinatorBegin, keyBegin, keyEnd
        case gazeBegin, gazeEnd, referentBegin, referentEnd, workCreated
        case executorBegin, resolveBegin, resolveEnd, driverBegin, driverEnd, driverFailed
        case executorEnd, cancelled
        case nativeActivationBegin, nativeActivationEnd, nativeActivationFailed, nativeForegroundVerified
        case nativeUnhideBegin, nativeUnhideEnd, nativeUnhideFailed
        case nativeForegroundReadBegin, nativeForegroundReadEnd
        case nativeTextInsertionBegin, nativeTextInsertionEnd, nativeTextInsertionFailed
        case nativeScrollBegin, nativeScrollEnd, nativeScrollUnavailable, nativeScrollUncertain, nativeScrollVerified
        case conversationRoutingBegin, conversationRoutingEnd
    }
    enum Tool: String, Codable, Sendable {
        case launchApp, listApps, listWindows, foreground, typeText, pressKey, other
        init(_ raw: String) {
            switch raw {
            case "launch_app": self = .launchApp
            case "list_apps": self = .listApps
            case "list_windows": self = .listWindows
            case "bring_to_front": self = .foreground
            case "type_text": self = .typeText
            case "press_key": self = .pressKey
            default: self = .other
            }
        }
    }
    struct Event: Codable, Sendable {
        let turn: UUID
        let task: UUID?
        let stage: Stage
        let tool: Tool?
        let monotonic: Double
    }
    private(set) var events: [Event] = []
    private(set) var dropped = 0

    func record(_ stage: Stage, turn: UUID, task: UUID? = nil, tool: Tool? = nil,
                at: Double = ProcessInfo.processInfo.systemUptime) {
        if events.lazy.filter({ $0.turn == turn }).count >= 64,
           let index = events.firstIndex(where: { $0.turn == turn }) {
            events.remove(at: index); dropped += 1
        }
        if events.count >= 256 { events.removeFirst(); dropped += 1 }
        events.append(Event(turn: turn, task: task, stage: stage, tool: tool,
                            monotonic: at))
    }

    func snapshot(since start: Double) -> [[String: Any]] {
        events.filter { $0.monotonic >= start }.map {
            var row: [String: Any] = ["turn": $0.turn.uuidString, "stage": $0.stage.rawValue,
                                      "monotonic": $0.monotonic]
            if let task = $0.task { row["task"] = task.uuidString }
            if let tool = $0.tool { row["tool"] = tool.rawValue }
            return row
        }
    }
}

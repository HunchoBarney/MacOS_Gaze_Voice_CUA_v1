import Foundation
import JevVoiceCore

@MainActor
struct DesktopSwitchAnswers {
    static let unknown = "I can’t verify a desktop switch. Which desktop did you mean?"
    private struct Receipt: Equatable {
        let code: DesktopSpaceSwitch.Code
        let origin: DesktopSpaceSwitch.Origin?
    }

    private struct Attempt {
        let capture: UUID
        let work: UUID
        let number: Int
        let display: UInt32
        let source: VoiceRealtimeInput
        var receipt: Receipt?
        var settledAt: TimeInterval?
    }

    private var turn: UUID?
    private var session: UUID?
    private var input: VoiceRealtimeInput?
    private var bound = false
    private var attempt: Attempt?

    mutating func invalidate() {
        attempt = nil
        bound = true
    }

    mutating func begin(_ id: UUID, conversation: UUID?) {
        if attempt?.capture != turn || attempt?.receipt == nil || (conversation != nil && conversation != session) {
            attempt = nil
        }
        turn = id
        session = conversation
        input = nil
        bound = false
    }

    mutating func source(_ source: VoiceRealtimeInput, for id: UUID) {
        guard turn == id else { return }
        if let input, input != source {
            bound = true
            attempt = nil
        }
        if let entry = attempt, entry.capture != id,
           entry.source.connectionID != source.connectionID || entry.source.itemID == source.itemID { attempt = nil }
        input = source
    }

    mutating func bind(_ work: VoiceTaskCoordinator.Work, to capture: UUID, conversation: UUID,
                       source: VoiceRealtimeInput, number: Int, display: UInt32,
                       works: [VoiceTaskCoordinator.Work], now: TimeInterval) {
        guard turn == capture, session == conversation, input == source else { return }
        guard !bound else { attempt = nil; return }
        bound = true
        attempt = Attempt(capture: capture, work: work.id, number: number, display: display, source: source)
        observe(works, now: now)
    }

    mutating func observe(_ works: [VoiceTaskCoordinator.Work], now: TimeInterval) {
        guard let entry = attempt else { return }
        let owners = works.filter { $0.captureID == entry.capture || $0.id == entry.work }
        if turn != entry.capture, works.contains(where: { $0.captureID == turn }) { attempt = nil; return }
        if owners.isEmpty, entry.receipt != nil { return }
        guard owners.count == 1, let work = owners.first, work.id == entry.work, work.captureID == entry.capture,
              work.desktopSwitch?.number == entry.number, work.desktopSwitch?.display == entry.display,
              DesktopSpaceTarget(command: work.request) == .numbered(entry.number) else { attempt = nil; return }
        if work.active && work.outcome == nil && entry.receipt == nil { return }
        guard !work.active, let code = work.desktopDecision else { attempt = nil; return }
        switch (code, work.outcome) {
        case (.pressAcceptedUnverified, .uncertain), (.pressRefused, .blocked):
            guard work.desktopOverviewOrigin != nil else { attempt = nil; return }
        case (.pressAcceptedUnverified, _), (.authorizationCancelled, _), (.authorityNotCurrent, _):
            attempt = nil; return
        case (_, .blocked): break
        default: attempt = nil; return
        }
        let receipt = Receipt(code: code, origin: work.desktopOverviewOrigin)
        if let original = entry.receipt {
            if receipt != original { attempt = nil }
        } else {
            attempt?.receipt = receipt
            attempt?.settledAt = now
        }
    }

    mutating func answer(for id: UUID, display: UInt32?, works: [VoiceTaskCoordinator.Work], now: TimeInterval) -> String? {
        guard turn == id else { return nil }
        observe(works, now: now)
        guard session == nil || input != nil, let entry = attempt, entry.capture != id, entry.display == display,
              let result = entry.receipt, let settled = entry.settledAt, (0...30).contains(now - settled)
        else { attempt = nil; return Self.unknown }
        let answer: String
        switch result.code {
        case .pressAcceptedUnverified:
            answer = "I requested Desktop \(entry.number), but I couldn’t verify the switch."
        case .pressRefused:
            answer = "I tried to select Desktop \(entry.number), but macOS didn’t confirm the request."
        case .authorizationCancelled, .authorityNotCurrent: return Self.unknown
        case .policyDenied, .displayChanged, .dockUnavailable, .dockTerminated, .accessibilityNotTrusted,
             .launcherUnavailable, .localeUnavailable, .rootUnreadable, .rootUnrecognized, .overviewUnreadable,
             .displayBindingUnavailable, .spacesGroupUnavailable, .spacesListUnavailable, .emptySpacesList,
             .malformedThumbnail, .targetMissing, .targetAmbiguous, .targetNotPressable, .targetChanged,
             .overviewClosedOnRecheck, .openFailed, .pollInterrupted, .overviewNotReady:
            answer = "I didn’t send a selection for Desktop \(entry.number)."
        }
        return result.origin == .launchRequested ? answer + " Mission Control may be open." : answer
    }
}

import XCTest
@testable import Jarvis

/// Contract: the voice task model — intent parsing decides scope/foreground
/// before the loop runs, and a Work row is the single unit of task state.
@MainActor
final class VoiceTaskContractTests: XCTestCase {

    // MARK: isPureOpenIntent

    func testPureOpenIntents() {
        for text in ["open Safari", "launch Notes", "start Terminal",
                     "bring up Mail", "Open Spotify"] {
            XCTAssertTrue(VoiceTaskCoordinator.isPureOpenIntent(text), text)
        }
    }

    /// Chained or purposive instructions are real work, not opens.
    func testCompoundInstructionsAreNotPureOpen() {
        for text in ["open Safari and go to apple.com",
                     "open Notes to write a reminder",
                     "launch Mail then send it",
                     "click the save button"] {
            XCTAssertFalse(VoiceTaskCoordinator.isPureOpenIntent(text), text)
        }
    }

    // MARK: wantsFrontmost

    func testFrontmostPhrasingDetected() {
        for text in ["close this app", "scroll this window",
                     "click the field in the frontmost app"] {
            XCTAssertTrue(VoiceTaskCoordinator.wantsFrontmost(text), text)
        }
        XCTAssertFalse(VoiceTaskCoordinator.wantsFrontmost("open Safari"))
    }

    // MARK: gerundPhrase

    func testGerundPhraseSkipsFillers() {
        XCTAssertEqual(VoiceTaskCoordinator.gerundPhrase(for: "please open Safari"),
                       "opening Safari")
        XCTAssertEqual(VoiceTaskCoordinator.gerundPhrase(for: "hey jev click save"),
                       "clicking save")
    }

    /// Non-verb instructions fall back to the raw request as the label.
    func testGerundPhraseFallback() {
        XCTAssertNil(VoiceTaskCoordinator.gerundPhrase(for: "   "))
        XCTAssertNil(VoiceTaskCoordinator.gerundPhrase(for: "next desktop"), "never \"nexting desktop\"")
        XCTAssertNil(VoiceTaskCoordinator.gerundPhrase(for: "new tab"), "never \"newing tab\"")
    }

    // MARK: Work row

    func testWorkStatusLifecycle() {
        let spec = DriveTask(goal: "g", pid: 1, windowID: 2)
        let work = VoiceTaskCoordinator.Work(label: "l", request: "r", spec: spec)
        XCTAssertEqual(work.statusText, "Working")
        XCTAssertNil(work.askPrompt)

        work.ask = .confirm("ok?")
        XCTAssertEqual(work.statusText, "Waiting")
        XCTAssertEqual(work.askPrompt, "ok?")

        work.ask = nil
        work.active = false
        work.outcome = .done
        XCTAssertEqual(work.statusText, "Done")
        work.outcome = .cancelled
        XCTAssertEqual(work.statusText, "Cancelled")
        _ = spec // spec is a value type; Work holds its own copy
    }

    // MARK: calibrationErrorBand (radial radius from measured error)

    /// The micro-radial's ambiguity band comes from the tracker's own
    /// accuracy report — better calibration reads a smaller band.
    func testCalibrationBandReadsReportMedian() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report: [String: Any] = [
            "kind": "accuracy-test",
            "error_px": ["overall": ["samples": 45, "median": 64.5, "p90": 120.0]],
        ]
        let url = dir.appendingPathComponent("accuracy_report.json")
        try JSONSerialization.data(withJSONObject: report).write(to: url)
        let prior = VoiceTaskCoordinator.accuracyReportURL
        defer { VoiceTaskCoordinator.accuracyReportURL = prior }
        VoiceTaskCoordinator.accuracyReportURL = url
        XCTAssertEqual(VoiceTaskCoordinator.calibrationErrorBand(), 64.5)
    }

    /// Missing or malformed reports contribute no band — the overlay's
    /// own floor keeps chips off the aim point.
    func testCalibrationBandMissingReportIsZero() {
        let prior = VoiceTaskCoordinator.accuracyReportURL
        defer { VoiceTaskCoordinator.accuracyReportURL = prior }
        VoiceTaskCoordinator.accuracyReportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-report-\(UUID().uuidString).json")
        XCTAssertEqual(VoiceTaskCoordinator.calibrationErrorBand(), 0)
    }

    // MARK: ordinalIndex (spoken picks → wire index)

    /// "the second one" resolves a parked choice — digits, cardinals,
    /// ordinals and "number N" all land on the same 0-based index the
    /// radial's onPick produces.
    func testOrdinalIndexMapsSpokenForms() {
        func pick(_ s: String, limit: Int = 4) -> Int? {
            if case .picked(let i) = VoiceTaskCoordinator.ordinalIndex(in: s, limit: limit) {
                return i
            }
            return nil
        }
        XCTAssertEqual(pick("2"), 1)
        XCTAssertEqual(pick("two"), 1)
        XCTAssertEqual(pick("the second one"), 1)
        XCTAssertEqual(pick("number 3"), 2)
        XCTAssertEqual(pick("3rd"), 2)
        XCTAssertEqual(pick("the first"), 0)
    }

    /// A recognized number outside the list asks again rather than
    /// guessing; a non-ordinal answer passes through for the loop.
    func testOrdinalIndexBoundsAndPassThrough() {
        if case .outOfRange = VoiceTaskCoordinator.ordinalIndex(in: "seven", limit: 3) {
        } else { XCTFail("seven should be out of range for 3 options") }
        if case .unparseable = VoiceTaskCoordinator.ordinalIndex(in: "the blue button", limit: 3) {
        } else { XCTFail("non-ordinal text should pass through") }
    }

    // MARK: AsyncLease (the focus/input mutex)

    /// Two holders never overlap — the second acquire parks until the
    /// first releases. This is the guarantee foreground-borrows and
    /// clipboard writes serialize on.
    func testLeaseSerializesHolders() async {
        let lease = AsyncLease()
        actor Log { var events: [String] = []
            func mark(_ e: String) { events.append(e) } }
        let log = Log()
        await lease.acquire()
        await log.mark("a-in")
        async let second: Void = {
            await lease.acquire()
            await log.mark("b-in")
            await log.mark("b-out")
            await lease.release()
        }()
        while await lease.queuedCount == 0, !(await log.events).contains("b-in") { await Task.yield() }
        await log.mark("a-out")
        await lease.release()
        await second
        let events = await log.events
        XCTAssertEqual(events, ["a-in", "a-out", "b-in", "b-out"])
    }

    // MARK: affirmative answers (the approval contract)

    func testAffirmativeAnswers() {
        for yes in ["yes", "yeah sure", "ok", "go ahead", "do it", "Yes."] {
            XCTAssertTrue(DriveLoop.affirmative(yes), yes)
        }
        for no in ["no", "stop", "nah", "cancel", ""] {
            XCTAssertFalse(DriveLoop.affirmative(no), no)
        }
        XCTAssertFalse(DriveLoop.affirmative(nil))
    }
}

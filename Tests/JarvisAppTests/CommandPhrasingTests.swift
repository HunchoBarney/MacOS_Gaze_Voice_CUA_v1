import XCTest
@testable import Jarvis

/// KAR-18: a request said another ordinary way does what the canonical
/// command does. Each row pairs a phrase with a canonical command, and the
/// pair is compared on what Jarvis would actually do: the admission
/// proposal and the fast action parsed from the same command text the
/// executor receives. "!" rows guard against over-reading.
///
/// `design.tsv` is the set the grammar was written against. `holdout.tsv`
/// was written at the same time by the same author and is only measured,
/// never tuned against. `blind.tsv` was written by a separate agent that
/// never saw the parser or the other sets.
final class CommandPhrasingTests: XCTestCase {
    private struct Row {
        let id, family, phrase, canonical: String
        let equivalent: Bool
    }

    /// Held-out rows that must keep passing. Set once from the final
    /// measurement; raise it when the grammar improves, never lower it.
    private static let heldOutFloor = 71
    private static let blindFloor = 66

    private static let context: VoiceAdmissionContext = {
        var context = VoiceAdmissionContext()
        context.entities = [("Safari", "com.apple.Safari"), ("Notes", "com.apple.Notes"),
                            ("Calculator", "com.apple.calculator"), ("Mail", "com.apple.mail"),
                            ("Messages", "com.apple.MobileSMS"), ("Spotify", "com.spotify.client")]
            .map { VoiceAdmissionContext.Entity(name: $0.0, id: $0.1, canOpenLocally: true) }
        context.targetAppID = "fixture.editor"; context.windowID = 42
        context.targetID = "fixture.editor.42"
        return context
    }()

    func testDesignPhrasesMeanTheirCanonicalCommand() throws {
        let failures = try measure("design")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testHeldOutPhrasesMeanTheirCanonicalCommand() throws {
        let rows = try rows("holdout")
        let failures = try measure("holdout")
        XCTAssertGreaterThanOrEqual(rows.count - failures.count, Self.heldOutFloor,
                                    failures.joined(separator: "\n"))
    }

    func testBlindPhrasesMeanTheirCanonicalCommand() throws {
        let rows = try rows("blind")
        let failures = try measure("blind")
        XCTAssertGreaterThanOrEqual(rows.count - failures.count, Self.blindFloor,
                                    failures.joined(separator: "\n"))
    }

    func testALeadInKeepsTheLiteralAsSaid() {
        XCTAssertEqual(VoiceAdmissionPolicy.commandText("I want to type Hello, World", context: Self.context),
                       "type Hello, World")
    }

    /// Runs one set, prints its pass rate by family, returns the failures.
    private func measure(_ set: String) throws -> [String] {
        let rows = try rows(set)
        XCTAssertFalse(rows.isEmpty)
        var failures: [String] = [], passed: [String: (Int, Int)] = [:]
        for row in rows {
            let canonical = meaning(row.canonical)
            XCTAssertFalse(canonical.hasPrefix("clarify") || canonical.hasPrefix("refuse"),
                           "\(row.id): canonical “\(row.canonical)” must itself be admitted, got \(canonical)")
            let phrase = meaning(row.phrase)
            let ok = (phrase == canonical) == row.equivalent
            let tally = passed[row.family] ?? (0, 0)
            passed[row.family] = (tally.0 + (ok ? 1 : 0), tally.1 + 1)
            if !ok {
                failures.append("\(row.id) “\(row.phrase)” → \(phrase); \(row.equivalent ? "=" : "!")“\(row.canonical)” → \(canonical)")
            }
        }
        let families = passed.keys.sorted().map { "\($0) \(passed[$0]!.0)/\(passed[$0]!.1)" }
        print("KAR-18 \(set): \(rows.count - failures.count)/\(rows.count) [\(families.joined(separator: ", "))]")
        for failure in failures { print("KAR-18 \(set) miss: \(failure)") }
        return failures
    }

    /// What Jarvis would do with a phrase: the admission proposal plus the
    /// fast action parsed from the command text the executor is handed. A
    /// trailing role word on a named control is dropped the way the
    /// element matcher drops it, so "the Save button" and "Save" compare
    /// equal.
    private func meaning(_ phrase: String) -> String {
        let proposal = VoiceAdmissionPolicy.propose(phrase, context: Self.context, speech: true)
        let command = VoiceAdmissionPolicy.commandText(phrase, context: Self.context)
        var action = "-"
        if let parsed = FastAction.parse(command) {
            switch parsed.action.body {
            case .clickNamed(let name): action = "clickNamed(\(Self.withoutRoleWord(name)))"
            case .showNamed(let name): action = "showNamed(\(Self.withoutRoleWord(name)))"
            default: action = String(describing: parsed.action.body)
            }
            action += " in \(parsed.appQualifier ?? "-")"
        }
        let slots = proposal.slots.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "\(proposal.route) \(proposal.intent) \(slots) \(proposal.targetIDs.sorted()) "
            + "\(proposal.reason) | \(action)"
    }

    private static func withoutRoleWord(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard words.count > 1, let last = words.last, NamedTargetMatch.roleWords.contains(String(last)) else { return name }
        return words.dropLast().joined(separator: " ")
    }

    private func rows(_ set: String) throws -> [Row] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/command-phrasings/\(set).tsv"),
                              encoding: .utf8)
        return text.split(separator: "\n").compactMap { line -> Row? in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let mark = fields[3].first, "=!".contains(mark) else { return nil }
            return Row(id: fields[0], family: fields[1], phrase: fields[2],
                       canonical: String(fields[3].dropFirst()), equivalent: mark == "=")
        }
    }
}

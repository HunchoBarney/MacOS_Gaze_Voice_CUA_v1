import XCTest
@testable import JevVoiceCore

final class IncrementalCommandCoordinatorTests: XCTestCase {
    let apps = ["Calculator", "Google Chrome", "TextEdit", "Spotify"]

    func testPayloadControlsAndPunctuationArePreserved() throws {
        let stream = IncrementalCommandCoordinator()
        for text in ["open TextEdit then I want you to type stop", "open TextEdit then I'd like you to write actually don't", "search for how to stop", "search for stop then open Spotify", "search for \"actually don't\""] {
            XCTAssertNil(stream.control(in: text), text)
        }
        for text in ["type Hello!", "write ???", "open TextEdit then type Really?!"] {
            XCTAssertEqual(try stream.next(in: text, final: true, installedApps: apps)?.text, text)
        }
        XCTAssertEqual(LocalCommandParser.parse("go back in Chrome", installedApps: apps, context: "TextEdit")?.targetApp, "Google Chrome")
    }

    func testCompleteLocalCommandCanRunBeforeFinalAndNeverReplays() throws {
        var stream = IncrementalCommandCoordinator()
        let text = "open Calculator"
        let first = try XCTUnwrap(stream.next(in: text, final: false, installedApps: apps))
        stream.commit(first, transcript: text)
        XCTAssertNil(try stream.next(in: "Open calculator.", final: true, installedApps: apps))
        let next = try XCTUnwrap(stream.next(in: "open Calculator and open Spotify", final: false, installedApps: apps))
        XCTAssertEqual(next.text, "open Spotify")
    }

    func testCommittedAppNameSpacingRevisionDoesNotReplayOrLoseContinuation() throws {
        var stream = IncrementalCommandCoordinator()
        let original = "Open text edit"
        stream.commit(try XCTUnwrap(stream.next(in: original, final: false, installedApps: apps)), transcript: original)
        XCTAssertNil(try stream.next(in: "Open TextEdit", final: false, installedApps: apps))
        XCTAssertEqual(try stream.next(in: "Open TextEdit\nCreate a new document", final: false, installedApps: apps)?.text, "Create a new document")
        XCTAssertThrowsError(try stream.next(in: "Open Calculator", final: true, installedApps: apps))
    }

    func testAmbiguousAndConditionalPrefixesNeverDispatchEarly() throws {
        for text in ["open", "open Google", "if I get home open Calculator", "don't open Calculator", "open Calculator and open Spotify tomorrow"] {
            XCTAssertNil(try IncrementalCommandCoordinator().next(in: text, final: false, installedApps: apps), text)
        }
    }

    func testQueryWaitsForFinalButPreparationCanProceed() throws {
        var stream = IncrementalCommandCoordinator()
        let text = "open Google Chrome and search for red"
        let launch = try XCTUnwrap(stream.next(in: text, final: false, installedApps: apps))
        XCTAssertEqual(launch.text, "open Google Chrome")
        stream.commit(launch, transcript: text)
        XCTAssertNil(try stream.next(in: text, final: false, installedApps: apps))
        XCTAssertEqual(try stream.next(in: text + " pandas", final: true, installedApps: apps)?.text, "search for red pandas")
    }

    func testLiteralSuffixOwnsCommandWordsAndStop() throws {
        XCTAssertNil(try IncrementalCommandCoordinator().next(in: "type hello and quit Spotify", final: false, installedApps: apps))
        let stream = IncrementalCommandCoordinator()
        XCTAssertNil(stream.control(in: "type stop and actually don't"))
        XCTAssertEqual(try stream.next(in: "type hello and quit Spotify", final: true, installedApps: apps)?.text, "type hello and quit Spotify")
    }

    func testRevisedCommittedPrefixCannotBeExecutedAgain() throws {
        var stream = IncrementalCommandCoordinator()
        let first = try XCTUnwrap(stream.next(in: "open Calculator", final: false, installedApps: apps))
        stream.commit(first, transcript: "open Calculator")
        XCTAssertThrowsError(try stream.next(in: "open Calendar", final: true, installedApps: apps))
    }

    func testRepeatedIntentionalCommandsHaveDistinctConsumption() throws {
        var stream = IncrementalCommandCoordinator()
        let full = "scroll down then scroll down"
        let first = try XCTUnwrap(stream.next(in: full, final: false, installedApps: apps))
        stream.commit(first, transcript: full)
        let second = try XCTUnwrap(stream.next(in: full, final: false, installedApps: apps))
        XCTAssertGreaterThan(second.endWord, first.endWord)
        stream.commit(second, transcript: full)
        XCTAssertNil(try stream.next(in: full, final: true, installedApps: apps))
    }

    func testCorrectionCanOvertakeUncommittedRequestButNotDictation() throws {
        let stream = IncrementalCommandCoordinator()
        XCTAssertEqual(stream.control(in: "open Calculator actually don't")?.kind, .undo)
        XCTAssertEqual(stream.control(in: "open Calculator actually open Spotify instead")?.kind, .replace)
        XCTAssertEqual(stream.control(in: "open Calculator stop then open Spotify", installedApps: apps)?.kind, .stop)
        XCTAssertNil(stream.control(in: "open TextEdit then type stop and quit Spotify"))
    }
}
